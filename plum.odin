package plum
import "core:crypto/sha2"
import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:terminal/ansi"

println :: fmt.println

Flags :: struct {
	rime_dir: string,
	pkg_dir:  string,
	isatty:   bool,
	conf:     string,
}
OPT: Flags

Package :: struct {
	repo:   string,
	branch: string,
}

fetch_package :: proc(
	pkg: Package,
) -> (
	state: os.Process_State,
	err: os.Error,
) {
	println_bold("Fetching:", pkg.repo)
	package_url := strings.concatenate(
		{"https://github.com/", pkg.repo, ".git"},
	)
	command := make([dynamic]string, context.temp_allocator)
	append(
		&command,
		"git",
		"clone",
		"--depth",
		"1",
		"--recurse-submodules",
		"--shallow-submodules",
	)
	if pkg.branch != "" {
		append(&command, "-b", pkg.branch)
	}
	append(&command, package_url)
	append(&command, repo_path(pkg))

	desc := os.Process_Desc {
		working_dir = OPT.pkg_dir,
		command     = command[:],
		stdout      = os.stdout,
		stderr      = os.stderr,
	}

	process := os.process_start(desc) or_return
	state = os.process_wait(process) or_return
	assert(state.exit_code == 0)

	return state, nil
}
update_package :: proc(
	pkg: Package,
) -> (
	state: os.Process_State,
	err: os.Error,
) {
	// TODO: switch branch if needed
	println_bold("Updating:", pkg.repo)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "git", "-C", repo_path(pkg), "pull", "--depth", "1")

	desc := os.Process_Desc {
		working_dir = OPT.pkg_dir,
		command     = command[:],
		stdout      = os.stdout,
		stderr      = os.stderr,
	}

	process := os.process_start(desc) or_return
	state = os.process_wait(process) or_return
	assert(state.exit_code == 0)

	return state, nil
}

load_pakcge_conf :: proc(path: string) -> (pkgs: []Package, err: os.Error) {
	packages := make([dynamic]Package, context.allocator)

	data := os.read_entire_file(path, context.allocator) or_return
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		trimed := strings.trim_space(line)
		if trimed == "" || strings.starts_with(trimed, "#") {continue}
		repo, _, branch := strings.partition(trimed, "@")
		pkg := Package{repo, branch}
		append(&packages, pkg)
	}

	return packages[:], nil
}

repo_path :: proc(pkg: Package) -> string {
	user, _, path := strings.partition(pkg.repo, "/")
	path = strings.trim_prefix(path, "rime-")
	return strings.concatenate({user, "/", path})
}

sha256_hash_file :: proc(
	f: ^os.File,
) -> (
	hash: [sha2.DIGEST_SIZE_256]byte,
	err: os.Error,
) {
	buffer: [1024]u8
	sha_ctx: sha2.Context_256
	sha2.init_256(&sha_ctx)

	for {
		n: int
		n, err = os.read(f, buffer[:])
		sha2.update(&sha_ctx, buffer[:n])
		if err != nil {
			if err == .EOF || err == .Broken_Pipe {
				err = nil
			}
			sha2.final(&sha_ctx, hash[:])
			return
		}
	}
}

// check sha256 sum before os.copy_file
//
// return true if copy is needed
copy_file :: proc(dst_path, src_path: string) -> (res: bool, err: os.Error) {
	src := os.open(src_path) or_return
	defer os.close(src)

	info := os.fstat(src, context.temp_allocator) or_return
	if info.type == .Directory {
		return false, .Invalid_File
	}

	if os.exists(dst_path) {
		dst := os.open(dst_path) or_return
		defer os.close(dst)
		dst_info := os.fstat(dst, context.temp_allocator) or_return
		if dst_info.size == info.size {
			src_hash := sha256_hash_file(src) or_return
			dst_hash := sha256_hash_file(dst) or_return
			if src_hash == dst_hash {
				return false, nil
			}
		}
	}

	dst := os.open(
		dst_path,
		{.Read, .Write, .Create, .Trunc},
		info.mode & os.Permissions_All,
	) or_return
	defer os.close(dst)

	_, err = io.copy(os.to_writer(dst), os.to_reader(src))

	return true, err
}

install_glob :: proc(root, pat: string) -> os.Error {
	p := os.join_path({root, pat}, context.temp_allocator) or_return

	files := os.glob(p) or_return
	for file in files {
		if strings.ends_with(file, ".custom.yaml") ||
		   strings.ends_with(file, "recipe.yaml") {
			continue
		}
		rel, _ := filepath.rel(root, file)
		dst_path := os.join_path(
			{OPT.rime_dir, rel},
			context.temp_allocator,
		) or_return
		copied := copy_file(dst_path, file) or_return
		if copied {
			println(rel)
		}
	}
	return nil
}

apply_patches :: proc(
	pkg: Package,
	root: string,
	patches: map[string][dynamic]string,
) -> os.Error {
	sb := strings.builder_make()
	for file, patch in patches {
		defer strings.builder_reset(&sb)

		println_bold("Patching:", file, color = ansi.FG_BLUE)

		strings.write_string(&sb, "# Rx: ")
		strings.write_string(&sb, pkg.repo)
		strings.write_string(&sb, ":: {")
		patch_header := strings.to_string(sb)
		strings.write_string(&sb, "\n")

		for line in patch {
			strings.write_string(&sb, line)
			strings.write_string(&sb, "\n")
		}

		strings.write_string(&sb, "# }\n")
		patch_content := strings.to_string(sb)

		path := os.join_path(
			{OPT.rime_dir, file},
			context.temp_allocator,
		) or_return

		if !os.exists(path) {
			println("Skip patching non-exist file:", path)
			continue
		}

		data := os.read_entire_file(path, context.temp_allocator) or_return

		f := os.open(path, {.Read, .Write, .Create, .Trunc}) or_return
		defer os.close(f)

		writer := os.to_writer(f)
		defer io.flush(writer)

		text := string(data)

		has_patch := false
		for line in strings.split_lines_iterator(&text) {
			if strings.trim_right_space(line) == "__patch:" {
				has_patch = true
			}
		}
		text = string(data)

		if has_patch {
			inpatch := false
			for line in strings.split_lines_iterator(&text) {
				if !inpatch {
					if line == patch_header {
						inpatch = true
						continue
					}
					io.write_string(writer, line)
					io.write_string(writer, "\n")
				} else {
					if line == "# }" {
						inpatch = false
						io.write_string(writer, patch_content)
						continue
					} else if line == strings.trim_space(line) {
						inpatch = false
						continue
					}
				}
			}
		} else {
			io.write_slice(writer, data)
			io.write_string(writer, "__patch:\n")
			io.write_string(writer, patch_content)
		}

	}
	return nil
}

install_package :: proc(pkg: Package) -> os.Error {
	println_bold("Installing:", pkg.repo)

	root := os.join_path(
		{OPT.pkg_dir, repo_path(pkg)},
		context.temp_allocator,
	) or_return
	recipe_path := os.join_path(
		{root, "recipe.yaml"},
		context.temp_allocator,
	) or_return

	if os.exists(recipe_path) {
		data := os.read_entire_file(
			recipe_path,
			context.temp_allocator,
		) or_return
		text := string(data)


		patches := make(map[string][dynamic]string)

		lines := strings.split_lines(text)

		for i := 0; i < len(lines); i += 1 {
			line := lines[i]
			trimed := strings.trim_space(line)
			if trimed == "" || strings.starts_with(trimed, "#") {continue}

			if trimed == "install_files: >-" {
				i += 1
				for ; i < len(lines); i += 1 {
					line = lines[i]
					trimed = strings.trim_space(line)
					if trimed == "" || strings.starts_with(trimed, "#") {
						continue
					}

					if trimed == line {
						i -= 1
						break
					}

					if trimed != line {
						install_glob(root, trimed)
					}
				}
			} else if trimed == "patch_files:" {
				i += 1
				indent_spaces := -1
				file: string

				for ; i < len(lines); i += 1 {
					line = lines[i]
					trimed = strings.trim_space(line)
					if trimed == "" || strings.starts_with(trimed, "#") {
						continue
					}

					if trimed == line {
						i -= 1
						break
					}

					indent := len(line) - len(strings.trim_left_space(line))
					if indent_spaces == -1 {
						indent_spaces = indent
					}

					if indent == indent_spaces {
						file = trimed[:len(trimed) - 1]
						patches[file] = make([dynamic]string)
					} else if indent >= 2 * indent_spaces {
						append(&patches[file], line[indent_spaces:])
					}
				}

			}

		}

		if err := apply_patches(pkg, root, patches); err != nil {
			println(err)
		}
	} else {
		install_glob(root, "*.yaml")
		install_glob(root, "*.txt")
		install_glob(root, "*.gram")
		install_glob(root, "opencc/*.json")
		install_glob(root, "opencc/*.ocd")
		install_glob(root, "opencc/*.txt")
		install_glob(root, "opencc/*.ocd2")
	}
	return nil
}

println_bold :: proc(
	args: ..any,
	color := ansi.FG_GREEN,
	sep := " ",
	flush := true,
) {
	if OPT.isatty {
		fmt.print(ansi.CSI + ansi.BOLD + ";")
		fmt.print(color)
		fmt.print(ansi.SGR)
	}
	fmt.println(..args, sep = sep, flush = flush)
	if OPT.isatty {
		fmt.print(ansi.CSI + ansi.RESET + ansi.SGR)
	}
}

default_opt :: proc() -> os.Error {
	home_dir := os.user_home_dir(context.allocator) or_return
	config_dir := os.user_config_dir(
		context.allocator,
		roaming = true,
	) or_return

	OPT.rime_dir = os.join_path(
		{config_dir, "Rime"},
		context.allocator,
	) or_return
	OPT.pkg_dir = os.join_path(
		{home_dir, ".cache", "plum"},
		context.allocator,
	) or_return
	OPT.isatty = os.is_tty(os.stdout)

	OPT.conf = os.join_path(
		{OPT.rime_dir, "./packages.conf"},
		context.allocator,
	) or_return

	return nil
}

main :: proc() {
	err: os.Error
	pkgs: []Package

	ensure(default_opt() == nil)
	flags.parse_or_exit(&OPT, os.args, .Unix)

	println_bold("RIME DIR:", OPT.rime_dir, color = ansi.FG_MAGENTA)
	println_bold("PKG DIR:", OPT.pkg_dir, color = ansi.FG_MAGENTA)
	println_bold("CONF:", OPT.conf, color = ansi.FG_MAGENTA)
	println()

	ensure(os.make_directory_all(OPT.pkg_dir) == nil)
	pkgs, err = load_pakcge_conf(OPT.conf)
	ensure(err == nil)

	for pkg in pkgs {
		state: os.Process_State

		gitpath, _ := os.join_path(
			{OPT.pkg_dir, repo_path(pkg), ".git"},
			context.allocator,
		)
		if !os.exists(gitpath) {
			if state, err = fetch_package(pkg); err != nil || !state.success {
				os.print_error(os.stderr, err, pkg.repo)
				continue
			}
		} else {
			if state, err = update_package(pkg); err != nil || !state.success {
				os.print_error(os.stderr, err, pkg.repo)
				continue
			}
		}

		if err = install_package(pkg); err != nil {
			os.print_error(os.stderr, err, pkg.repo)
			continue
		}

	}
}

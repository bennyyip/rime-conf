#!/bin/sh

set -e

ODIN_FLAGS='-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -source-code-locations:filename'

build() {
  odin build $ODIN_FLAGS -o:size -no-bounds-check -subsystem:console -out:plum.exe .
}

case "$1" in
  run)
    odin run .
    ;;
  build)
    build
    ;;
  install)
    build
    mv plum.exe ~/bin/plum.exe
    ;;
  clean)
    rm -f plum.exe
    ;;
  *)
    build
    ;;
esac


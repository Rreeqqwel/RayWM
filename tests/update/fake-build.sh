#!/bin/sh
# Stand-in for scripts/arch-package.sh inside fake source archives
# (tests/update/world.py): records how it was run and writes a text
# "package" for tests/update/fake-pacman.sh. FAKE_BUILD_FAIL=1 fails.
set -eu
tag=$1; src=$2; out=$3
echo "build $tag uid=$(id -u) archive=$(basename "$src")" >>"$FAKE_LOG"
[ -z "${FAKE_BUILD_FAIL:-}" ] || { echo "fake-build: compilation failed" >&2; exit 1; }
v=${tag#v}; v=${v%%-*}; pre=${tag#*-beta}
case "$tag" in *-beta) pv="${v}beta" ;; *-beta.*) pv="${v}beta${pre}" ;; esac
mkdir -p "$out"
printf 'Name            : raywm\nVersion         : %s-1\nArchitecture    : x86_64\n--files\nraywm /usr/\nraywm /usr/bin/\nraywm /usr/bin/raywm\nraywm /usr/bin/raywm-update\nraywm /usr/share/raywm/\n' "$pv" \
    >"$out/raywm-$pv-1-x86_64.pkg.tar.zst"

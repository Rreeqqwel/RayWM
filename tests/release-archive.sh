#!/bin/sh
# Verifies a Beta source archive (scripts/source-archive.sh).
# Usage: tests/release-archive.sh ARCHIVE TAG [--build]
#   --build  also build it from the extracted archive (network-isolated
#            when unshare is permitted) and run the unit tests there.
set -eu
archive=${1:?usage: tests/release-archive.sh ARCHIVE TAG [--build]}
tag=${2:?usage}
build=${3:-}
zig=${ZIG:-zig}
root=$(cd "$(dirname "$0")/.." && pwd)
failures=0
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
name="raywm-$tag"
[ "$(basename "$archive")" = "$name.tar.gz" ] && ok || fail "archive name is not $name.tar.gz"
if [ -e "$archive.sha256" ]; then
    (cd "$(dirname "$archive")" && sha256sum -c --quiet "$(basename "$archive").sha256") && ok || fail "sha256 mismatch"
else fail "missing $archive.sha256"; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
tar -xzf "$archive" -C "$tmp"
[ "$(ls "$tmp")" = "$name" ] && ok || fail "top-level directory is not $name/"
d="$tmp/$name"
for f in build.zig build.zig.zon LICENSE README.md CHANGELOG.md SECURITY.md SOURCE-INFO \
    src/main.zig src/server.zig protocol tests/client.zig tests/core_test.zig tests/lua_test.zig \
    config/init.lua config/rules.lua config/plugins/dwindle.lua config/plugins/binds.lua \
    config/plugins/outputs.lua scripts/raywmctl scripts/install.sh scripts/arch-package.sh \
    scripts/source-archive.sh scripts/release-meta.py packaging/arch/PKGBUILD.in \
    packaging/arch/raywm.desktop packaging/arch/raywm.install docs/INSTALL.md docs/GAMING.md \
    docs/RELEASE-WORKFLOW.md zig-pkg; do
    [ -e "$d/$f" ] && ok || fail "missing $f"
done
for dep in wlroots wayland xkbcommon pixman; do
    ls "$d/zig-pkg" | grep -q "^$dep-" && ok || fail "zig-pkg lacks $dep"
done
for f in .github .claude CLAUDE.md docs/measurements zig-out .zig-cache dist recovery graphify-out; do
    [ ! -e "$d/$f" ] && ok || fail "must not contain $f"
done
grep -qx "tag=$tag" "$d/SOURCE-INFO" && ok || fail "SOURCE-INFO tag"
python3 "$root/scripts/release-meta.py" check-zon "$tag" "$d/build.zig.zon" && ok || fail "build.zig.zon version"
elf=$(find "$d" -type f -exec sh -c 'head -c4 "$1" | grep -q "ELF"' _ {} \; -print)
[ -z "$elf" ] && ok || fail "binaries in archive: $elf"
find "$d" -name '*.pkg.tar.*' | grep -q . && fail "package file in archive" || ok
if [ "$build" = --build ]; then
    isolate=""
    if unshare -rn true 2>/dev/null; then isolate="unshare -rn"; fi
    (cd "$d" && ZIG_GLOBAL_CACHE_DIR="$tmp/gcache" $isolate "$zig" build -Doptimize=ReleaseSafe -Dcpu=baseline -p "$tmp/out") && ok || fail "build from archive"
    "$tmp/out/bin/raywm" -h >/dev/null 2>&1 && ok || fail "built raywm -h"
    (cd "$d" && ZIG_GLOBAL_CACHE_DIR="$tmp/gcache" $isolate "$zig" build test >/dev/null 2>&1) && ok || fail "unit tests from archive"
    echo "release-archive: built from the archive${isolate:+ without network}"
fi
if [ "$failures" -eq 0 ]; then echo "release-archive: $checks checks passed"; else echo "release-archive: $failures failure(s)"; exit 1; fi

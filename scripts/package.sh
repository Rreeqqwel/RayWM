#!/bin/sh
# Build a local, reproducible ReleaseSafe archive; never publish or tag.
# Usage: [ZIG=/path/to/zig] scripts/package.sh v0.2.1
set -eu
umask 022
export LC_ALL=C
version=${1:?usage: scripts/package.sh v0.2.1}
zig=${ZIG:-zig}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || { echo 'package: invalid version'; exit 2; }
[ "$("$zig" version)" = 0.16.0 ] || { echo 'package: Zig 0.16.0 required'; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo 'package: only Linux x86_64 builds are packaged'; exit 1; }
[ "$(uname -s)" = Linux ] || exit 1
expected=${version#v}
actual=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)
[ "$actual" = "$expected" ] || { echo 'package: version does not match build.zig.zon'; exit 1; }
api_version=$(sed -n 's/^pub const version = "\([^"]*\)";.*/\1/p' src/lua.zig)
[ "$api_version" = "$expected" ] || { echo 'package: version does not match Lua host'; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo 'package: commit tracked changes first'; exit 1; }
# Preserve unrelated untracked handoff files; package only committed inputs.
[ -z "$(git ls-files --others --exclude-standard src protocol config)" ] || { echo 'package: untracked build/config inputs'; exit 1; }
commit=$(git rev-parse HEAD)
epoch=$(git log -1 --format=%ct)
dist=${RAYWM_DIST_DIR:-$root/dist}
mkdir -p "$dist"
dist=$(cd "$dist" && pwd)
work=$(mktemp -d "$dist/.package.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
name="raywm-$version"
stage="$work/$name"
mkdir -p "$stage/bin"
git archive HEAD README.md LICENSE CHANGELOG.md SECURITY.md config docs scripts/install.sh scripts/raywmctl | tar -xf - -C "$stage"
install -m 0755 "$stage/scripts/install.sh" "$stage/install.sh"
install -m 0755 "$stage/scripts/raywmctl" "$stage/bin/raywmctl"
# Remove only the temporary copies; they are not archive paths.
rm -rf "$stage/scripts"
"$zig" build -Doptimize=ReleaseSafe -Dcpu=baseline -Dtest-input=false -p "$work/build"
bin="$work/build/bin/raywm"
if nm -D "$bin" | grep -q wlr_virtual_pointer_manager_v1_create || strings "$bin" | grep -q 'TEST BUILD: virtual pointer' || strings "$bin" | grep -q raywm-test-unplug; then
    echo 'package: test-only code in release binary'; exit 1
fi
install -m 0755 "$bin" "$stage/bin/raywm"
strip --strip-all "$stage/bin/raywm"
printf '%s\n' "$commit" >"$stage/COMMIT"
{
    printf 'version=%s\ncommit=%s\nsource_date_epoch=%s\noptimize=ReleaseSafe\ntest_input=false\n' "$version" "$commit" "$epoch"
    printf 'zig=%s\n' "$("$zig" version)"
    for lib in wlroots-0.20 wayland-server wayland-protocols lua5.4 xkbcommon pixman-1 libinput; do
        printf '%s=%s\n' "$lib" "$(pkg-config --modversion "$lib")"
    done
    strip --version | head -1
} >"$stage/BUILD-INFO"
# Hash the complete payload before adding its own checksum manifest.
(cd "$stage" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$work/MANIFEST.sha256"
install -m 0644 "$work/MANIFEST.sha256" "$stage/MANIFEST.sha256"
archive="$name-linux-x86_64.tar.gz"
(cd "$work" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -cf - "$name" | gzip -n -9) >"$work/$archive"
if [ -e "$dist/$archive" ]; then
    cmp -s "$work/$archive" "$dist/$archive" || { echo 'package: different archive already exists; preserve it before rebuilding'; exit 1; }
else
    # Atomic publication inside dist, without replacing an existing artifact.
    ln "$work/$archive" "$dist/$archive"
fi
(cd "$dist" && sha256sum "$archive") >"$work/$archive.sha256"
if [ -e "$dist/$archive.sha256" ]; then
    cmp -s "$work/$archive.sha256" "$dist/$archive.sha256" || { echo 'package: existing checksum differs'; exit 1; }
else
    ln "$work/$archive.sha256" "$dist/$archive.sha256"
fi
# Keep SHA256SUMS for the installer instructions, preserving older entries.
if [ ! -e "$dist/SHA256SUMS" ] || ! grep -qF "  $archive" "$dist/SHA256SUMS"; then
    cat "$work/$archive.sha256" >>"$dist/SHA256SUMS"
fi
printf 'package: %s/%s\n' "$dist" "$archive"
cat "$work/$archive.sha256"

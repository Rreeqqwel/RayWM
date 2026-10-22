#!/bin/sh
# Builds the release binary (ReleaseSafe) and the distributable archive:
#   dist/raywm-<version>-linux-x86_64.tar.gz  and  dist/SHA256SUMS
#   usage: [ZIG=/path/to/zig] scripts/package.sh v0.1.1
# The archive is reproducible for a given commit and toolchain (sorted
# entries, fixed owner, mtime = commit time).
set -eu
version=${1:?usage: scripts/package.sh <version, e.g. v0.1.1>}
zig=${ZIG:-zig}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

[ "$("$zig" version)" = 0.16.0 ] || { echo "package: Zig 0.16.0 required, found $("$zig" version)"; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "package: only x86_64 builds are packaged"; exit 1; }

name="raywm-$version"
dist="$root/dist"
rm -rf "$dist"
mkdir -p "$dist/build"

# Release build without the test-only virtual input protocols.
"$zig" build -Doptimize=ReleaseSafe -Dtest-input=false -p "$dist/build"
bin="$dist/build/bin/raywm"
if strings "$bin" | grep -qi virtual_pointer; then echo "package: test-only code in release binary"; exit 1; fi

stage="$dist/$name"
mkdir -p "$stage/bin" "$stage/config" "$stage/docs"
install -m 0755 "$bin" "$stage/bin/raywm"
install -m 0644 config/init.lua "$stage/config/init.lua"
cp -r config/plugins "$stage/config/plugins"
chmod 0644 "$stage/config/plugins/"*.lua
install -m 0644 README.md LICENSE CHANGELOG.md SECURITY.md "$stage/"
install -m 0644 docs/*.md "$stage/docs/"
mkdir -p "$stage/docs/screenshots" && install -m 0644 docs/screenshots/*.png "$stage/docs/screenshots/"
install -m 0755 scripts/install.sh "$stage/install.sh"
git rev-parse HEAD >"$stage/COMMIT"

epoch=$(git log -1 --format=%ct)
archive="$name-linux-x86_64.tar.gz"
(cd "$dist" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -cf - "$name" | gzip -n -9 >"$archive")
(cd "$dist" && sha256sum "$archive" >SHA256SUMS)

echo "package: $dist/$archive"
cat "$dist/SHA256SUMS"

#!/bin/sh
# Beta distribution: a reproducible, self-contained source archive.
# Usage: [ZIG=zig] scripts/source-archive.sh TAG OUT_DIR [REF]
#   TAG     release tag, e.g. v0.2.1-beta (also names the archive)
#   REF     commit to archive (default: TAG)
# Produces OUT_DIR/raywm-TAG.tar.gz and its .sha256. The archive holds the
# committed sources needed to build (src, protocol, tests used by build.zig,
# config and plugins, scripts, packaging, user documentation) plus the
# pinned Zig package dependencies (zig-pkg/), so it builds without network.
# It never contains a RayWM binary; CI/agent files and raw measurement data
# are left out. Never publishes anything.
set -eu
umask 022
export LC_ALL=C
tag=${1:?usage: scripts/source-archive.sh TAG OUT_DIR [REF]}
out=${2:?usage: scripts/source-archive.sh TAG OUT_DIR [REF]}
ref=${3:-$tag}
zig=${ZIG:-zig}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
python3 scripts/release-meta.py parse "$tag" >/dev/null
commit=$(git rev-parse "$ref^{commit}")
epoch=$(git log -1 --format=%ct "$commit")
name="raywm-$tag"
mkdir -p "$out"
out=$(cd "$out" && pwd)
[ ! -e "$out/$name.tar.gz" ] || { echo "source-archive: $out/$name.tar.gz exists; refusing to overwrite"; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
stage="$work/$name"
mkdir -p "$stage"
git archive "$commit" -- . ':(exclude).github' ':(exclude).claude' ':(exclude)CLAUDE.md' \
    ':(exclude)docs/measurements' ':(exclude).gitignore' | tar -xf - -C "$stage"
git show "$commit:build.zig.zon" >/dev/null
python3 scripts/release-meta.py check-zon "$tag" "$stage/build.zig.zon"
# Pinned dependencies (hashes are checked by Zig against build.zig.zon).
(cd "$stage" && ZIG_GLOBAL_CACHE_DIR="$work/zig-cache" "$zig" build --fetch >/dev/null)
[ -d "$stage/zig-pkg" ] || { echo 'source-archive: zig build --fetch produced no zig-pkg/'; exit 1; }
rm -rf "$stage/.zig-cache"
{
    printf 'tag=%s\ncommit=%s\nsource_date_epoch=%s\n' "$tag" "$commit" "$epoch"
    printf 'zig=%s\n' "$("$zig" version)"
    printf 'build=zig build -Doptimize=ReleaseSafe -Dcpu=baseline (see docs/INSTALL.md)\n'
} >"$stage/SOURCE-INFO"
if find "$stage" -type f -exec sh -c 'head -c4 "$1" | grep -q "ELF"' _ {} \; -print | grep -q .; then
    echo 'source-archive: ELF binary in archive'; exit 1
fi
(cd "$work" && tar --sort=name --owner=0 --group=0 --numeric-owner --mode=go-w --mtime="@$epoch" -cf - "$name" | gzip -n -9) >"$out/$name.tar.gz"
(cd "$out" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
cat "$out/$name.tar.gz.sha256"

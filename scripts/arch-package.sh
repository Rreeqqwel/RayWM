#!/bin/sh
# Stable distribution: a pacman package built with makepkg from a release
# source archive. Run as an unprivileged user (makepkg refuses root).
# Usage: scripts/arch-package.sh TAG SOURCE_ARCHIVE OUT_DIR
# Produces OUT_DIR/raywm-PKGVER-1-x86_64.pkg.tar.zst, its .sha256, and the
# filled-in PKGBUILD used (OUT_DIR/PKGBUILD) for reproducibility.
set -eu
umask 022
export LC_ALL=C
tag=${1:?usage: scripts/arch-package.sh TAG SOURCE_ARCHIVE OUT_DIR}
src=${2:?usage}
out=${3:?usage}
root=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" -ne 0 ] || { echo 'arch-package: makepkg must not run as root'; exit 1; }
pkgver=$(python3 "$root/scripts/release-meta.py" parse "$tag" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pkgver"])')
[ "$(basename "$src")" = "raywm-$tag.tar.gz" ] || { echo "arch-package: expected raywm-$tag.tar.gz"; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
pkg="raywm-$pkgver-1-x86_64.pkg.tar.zst"
[ ! -e "$out/$pkg" ] || { echo "arch-package: $out/$pkg exists; refusing to overwrite"; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
sum=$(sha256sum "$src" | cut -d' ' -f1)
sed -e "s|@PKGVER@|$pkgver|" -e "s|@TAG@|$tag|" -e "s|@SOURCE_SHA256@|$sum|" \
    "$root/packaging/arch/PKGBUILD.in" >"$work/PKGBUILD"
cp "$root/packaging/arch/raywm.desktop" "$root/packaging/arch/raywm.install" "$src" "$work/"
(cd "$work" && SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)} PKGDEST="$out" makepkg --noconfirm --cleanbuild >"$work/makepkg.log" 2>&1) ||
    { tail -60 "$work/makepkg.log"; exit 1; }
[ -e "$out/$pkg" ] || { echo "arch-package: makepkg did not produce $pkg"; ls "$out"; exit 1; }
cp "$work/PKGBUILD" "$out/PKGBUILD"
(cd "$out" && sha256sum "$pkg" >"$pkg.sha256")
cat "$out/$pkg.sha256"

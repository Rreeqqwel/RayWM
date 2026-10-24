#!/bin/sh
# Verifies a pacman package built by scripts/arch-package.sh: the Stable
# release asset, or what raywm-update builds from a Beta source archive.
# Usage: tests/release-package.sh PACKAGE TAG
# Reads metadata with pacman, inspects the payload without installing it,
# and runs the packaged binary headless with the packaged configuration.
set -eu
pkg=${1:?usage: tests/release-package.sh PACKAGE TAG}
tag=${2:?usage}
root=$(cd "$(dirname "$0")/.." && pwd)
failures=0
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
pkgver=$(python3 "$root/scripts/release-meta.py" parse "$tag" | python3 -c 'import json,sys; j=json.load(sys.stdin); assert j["channel"] in ("beta", "stable"); print(j["pkgver"])') || { echo "release-package: $tag is not a beta or stable tag"; exit 1; }
[ "$(basename "$pkg")" = "raywm-$pkgver-1-x86_64.pkg.tar.zst" ] && ok || fail "file name is not raywm-$pkgver-1-x86_64.pkg.tar.zst"
if [ -e "$pkg.sha256" ]; then
    (cd "$(dirname "$pkg")" && sha256sum -c --quiet "$(basename "$pkg").sha256") && ok || fail "sha256 mismatch"
else fail "missing $pkg.sha256"; fi
info=$(pacman -Qip "$pkg")
field() { printf '%s\n' "$info" | sed -n "s/^$1 *: //p"; }
[ "$(field Name)" = raywm ] && ok || fail "Name"
[ "$(field Version)" = "$pkgver-1" ] && ok || fail "Version $(field Version)"
[ "$(field Architecture)" = x86_64 ] && ok || fail "Architecture"
[ "$(field Licenses)" = GPL-3.0-only ] && ok || fail "Licenses"
for dep in wlroots0.20 wayland libxkbcommon pixman lua54 libinput python curl tar; do
    field 'Depends On' | tr ' ' '\n' | grep -qx "$dep" && ok || fail "Depends On lacks $dep"
done
files=$(pacman -Qlp "$pkg" | cut -d' ' -f2-)
for f in /usr/bin/raywm /usr/bin/raywmctl /usr/bin/raywm-update /usr/share/raywm/config/raywm.conf \
    /usr/share/raywm/config/init.lua /usr/share/raywm/config/rules.lua \
    /usr/share/raywm/config/plugins/dwindle.lua /usr/share/raywm/config/plugins/outputs.lua \
    /usr/share/wayland-sessions/raywm.desktop /usr/share/licenses/raywm/LICENSE \
    /usr/share/doc/raywm/README.md /usr/share/doc/raywm/docs/GAMING.md /usr/share/doc/raywm/docs/CONFIGURATION.md \
    /usr/share/doc/raywm/docs/INSTALL.md; do
    printf '%s\n' "$files" | grep -qx "$f" && ok || fail "missing $f"
done
printf '%s\n' "$files" | grep -v '^/usr/' | grep -q . && fail "files outside /usr: $(printf '%s\n' "$files" | grep -v '^/usr/' | head -3)" || ok
printf '%s\n' "$files" | grep -q 'raywm-test' && fail "test-only program packaged" || ok
# The channel file is created by the scriptlet, never owned by the package.
printf '%s\n' "$files" | grep -q '^/etc' && fail "package owns files in /etc" || ok
tmp=$(mktemp -d)
trap 'kill "$(cat "$tmp/pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$tmp"' EXIT HUP INT TERM
bsdtar -xf "$pkg" -C "$tmp" 2>/dev/null || tar --zstd -xf "$pkg" -C "$tmp"
[ -e "$tmp/.PKGINFO" ] && [ -e "$tmp/.MTREE" ] && [ -e "$tmp/.INSTALL" ] && ok || fail ".PKGINFO/.MTREE/.INSTALL"
bin="$tmp/usr/bin/raywm"
file "$bin" | grep -q 'ELF 64-bit LSB pie executable, x86-64\|ELF 64-bit LSB executable, x86-64' && ok || fail "not an x86-64 ELF executable"
ldd "$bin" | grep -q 'not found' && fail "missing shared libraries" || ok
nm -D "$bin" | grep -q wlr_virtual_pointer_manager_v1_create && fail "test-only virtual input" || ok
strings "$bin" | grep -q 'TEST BUILD: virtual pointer\|raywm-test-unplug' && fail "test-only strings" || ok
# Built for baseline x86-64: no AVX/AVX2 vector registers.
[ "$(objdump -d "$bin" | grep -c '%ymm\|%zmm')" -eq 0 ] && ok || fail "binary needs AVX (not -Dcpu=baseline)"
"$bin" -h >/dev/null 2>&1 && ok || fail "raywm -h"
"$tmp/usr/bin/raywm-update" --help >/dev/null 2>&1 && ok || fail "raywm-update --help"
grep -q '_raywm_channel_init' "$tmp/.INSTALL" && ok || fail ".INSTALL does not initialize the update channel"
# The packaged raywm.conf as the system layer is valid and equals the defaults.
RAYWM_SYSTEM_CONF="$tmp/usr/share/raywm/config/raywm.conf" "$bin" -t -c /nonexistent/init.lua >"$tmp/conf-check" 2>&1 && ok || fail "packaged raywm.conf: $(cat "$tmp/conf-check")"
# Headless start with the packaged default configuration and raywmctl.
run="$tmp/run"; mkdir -p "$run/config"; chmod 700 "$run"
cp -r "$tmp/usr/share/raywm/config" "$run/config/raywm"
env -i PATH="$PATH" HOME="$run" XDG_RUNTIME_DIR="$run" XDG_CONFIG_HOME="$run/config" WLR_BACKENDS=headless \
    WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 RAYWM_XWAYLAND=0 \
    "$bin" -s "echo \$WAYLAND_DISPLAY >'$run/display'" >"$run/raywm.log" 2>&1 &
echo $! >"$tmp/pid"
i=0; while [ ! -s "$run/display" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
if [ -s "$run/display" ]; then
    ok
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$run" WAYLAND_DISPLAY="$(cat "$run/display")" python3 "$tmp/usr/bin/raywmctl" perf >"$run/perf.json" 2>&1 &&
        python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['outputs']" "$run/perf.json" && ok || fail "packaged raywmctl perf"
    grep -E 'panic|\[ERROR\]|error\(' "$run/raywm.log" && fail "errors with the packaged config" || ok
else fail "packaged raywm did not start: $(tail -5 "$run/raywm.log")"; fi
kill "$(cat "$tmp/pid")" 2>/dev/null || true
if [ "$failures" -eq 0 ]; then echo "release-package: $checks checks passed"; else echo "release-package: $failures failure(s)"; exit 1; fi

#!/bin/sh
# Installs, reinstalls and removes a RayWM package with the real pacman in a
# disposable root environment (the CI container): the scriptlet creates
# /etc/raywm/update.conf once from the package's channel, pacman never owns
# or replaces it, upgrades/reinstalls and removal keep a changed channel,
# raywm-update reads and switches it. Destroys any existing RayWM install
# and channel file: never run it on a real system.
# Usage: tests/release-install.sh PACKAGE TAG
set -eu
pkg=${1:?usage: tests/release-install.sh PACKAGE TAG}
tag=${2:?usage}
root=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" -eq 0 ] || { echo "release-install: needs root (CI container only)"; exit 2; }
[ -n "${CI:-}" ] || [ -n "${RAYWM_DISPOSABLE_ROOT:-}" ] || { echo "release-install: refusing outside CI (set RAYWM_DISPOSABLE_ROOT=1 in a throwaway container)"; exit 2; }
failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
conf=/etc/raywm/update.conf
channel=$(python3 "$root/scripts/release-meta.py" parse "$tag" | python3 -c 'import json,sys; print(json.load(sys.stdin)["channel"])')
other=$([ "$channel" = beta ] && echo stable || echo beta)
has() { grep -qx "channel=$1" "$conf" 2>/dev/null || fail "$2: $(grep -v '^#' "$conf" 2>/dev/null || echo 'no update.conf'), expected channel=$1"; }

pacman -R --noconfirm raywm >/dev/null 2>&1 || true
rm -f "$conf"
pacman -U --noconfirm "$pkg"
has "$channel" "first install"
pacman -Qo "$conf" >/dev/null 2>&1 && fail "pacman owns $conf"
raywm-update --channel | grep -q "^Channel: $channel ($conf)" || fail "raywm-update --channel"
raywm-update --set-channel "$other" | grep -q "Channel: $other (was $channel)" || fail "raywm-update --set-channel $other"
has "$other" "after --set-channel"
[ "$(stat -c '%a %U' "$conf")" = "644 root" ] || fail "mode/owner $(stat -c '%a %U' "$conf")"
pacman -U --noconfirm "$pkg"        # reinstall: the upgrade scriptlet runs
has "$other" "after reinstalling (upgrade scriptlet)"
pacman -R --noconfirm raywm
[ ! -e /usr/bin/raywm ] && [ ! -e /usr/bin/raywm-update ] || fail "binaries left after removal"
[ ! -e /usr/share/raywm ] || fail "/usr/share/raywm left after removal"
has "$other" "after removal"
pacman -U --noconfirm "$pkg"
has "$other" "after installing again"
raywm-update --set-channel nightly >/dev/null 2>&1 && fail "accepted channel nightly"
has "$other" "after a refused --set-channel"
pacman -R --noconfirm raywm
rm -f "$conf"
if [ "$failures" -eq 0 ]; then echo "release-install: OK ($channel package; channel kept across reinstall, removal and install)"; else echo "release-install: $failures failure(s)"; exit 1; fi

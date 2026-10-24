#!/bin/sh
# raywm-update and the package's channel scriptlet, against local fixtures
# only: a fake GitHub release list and assets (file:// URLs, built by
# tests/update/world.py), a fake pacman (tests/update/fake-pacman.sh) and a
# fake Beta build (tests/update/fake-build.sh). The real curl, vercmp and
# tar are used; nothing is published, downloaded from the network or
# installed. Run it as an unprivileged user; as root it only checks that a
# Beta is never built as root (CI runs both).
#   usage: [KEEP=1] [ONLY=substring] tests/update.sh [bin-dir]
set -eu
bin=$(cd "${1:-zig-out/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
upd="$bin/raywm-update"
[ -x "$upd" ] || { echo "update: missing $upd (zig build)"; exit 2; }
command -v vercmp >/dev/null || { echo "update: vercmp (pacman) is required"; exit 2; }
failures=0
scenarios=0

# setup <installed-version|-> <channel|-> <release specs...>
setup() {
    scenarios=$((scenarios + 1)); before=$failures
    tmp=$(mktemp -d)
    mkdir -p "$tmp/etc/raywm" "$tmp/home/.config/raywm"
    if [ "$1" = - ]; then : >"$tmp/db"; else echo "$1" >"$tmp/db"; fi
    [ "$2" = - ] || printf 'channel=%s\n' "$2" >"$tmp/etc/raywm/update.conf"
    shift 2
    python3 "$root/tests/update/world.py" "$tmp/world" "$@"
    # A user configuration that no step may touch.
    printf '[appearance]\ninner_gaps = 3\n' >"$tmp/home/.config/raywm/raywm.conf"
    echo 'raywm.load("dwindle")' >"$tmp/home/.config/raywm/init.lua"
    (cd "$tmp/home/.config/raywm" && sha256sum raywm.conf init.lua) >"$tmp/user.sha256"
}
# upd <args...>: raywm-update in the fixture world; output in $tmp/out, status in $st.
upd() {
    st=0
    env -i PATH="$PATH" HOME="$tmp/home" USER=tester \
        RAYWM_UPDATE_API="file://$tmp/world/api/releases-{page}.json" \
        RAYWM_UPDATE_CONF="$tmp/etc/raywm/update.conf" RAYWM_UPDATE_PACMAN="$root/tests/update/fake-pacman.sh" \
        RAYWM_UPDATE_SUDO= RAYWM_UPDATE_CACHE="$tmp/cache" \
        FAKE_DB="$tmp/db" FAKE_LOG="$tmp/calls.log" ${FAKE_ENV:-} \
        "$upd" "$@" </dev/null >"$tmp/out" 2>&1 || st=$?
}
fail() { echo "FAIL [$name] $1"; failures=$((failures + 1)); }
status() { [ "$st" -eq "$1" ] || fail "exit status $st, expected $1"; }
says() { grep -qE -- "$1" "$tmp/out" || fail "output lacks /$1/"; }
silent() { if grep -qE -- "$1" "$tmp/out"; then fail "output has /$1/"; fi; }
installed() { [ "$(cat "$tmp/db")" = "$1" ] || fail "installed '$(cat "$tmp/db")', expected '$1'"; }
channel() { grep -qx "channel=$1" "$tmp/etc/raywm/update.conf" || fail "update.conf: $(cat "$tmp/etc/raywm/update.conf" 2>/dev/null | grep -v '^#' || echo missing), expected channel=$1"; }
no_install() { if grep -q '^pacman -U' "$tmp/calls.log" 2>/dev/null; then fail "pacman -U was run"; fi; }
built() { grep -q "^build $1 uid=$(id -u)" "$tmp/calls.log" || fail "no non-root Beta build of $1"; }
finish() {
    # The working directory is always removed, and the user's files are intact.
    if [ -d "$tmp/cache" ] && [ -n "$(ls -A "$tmp/cache")" ]; then fail "left files in the cache: $(ls -A "$tmp/cache")"; fi
    (cd "$tmp/home/.config/raywm" && sha256sum -c --quiet "$tmp/user.sha256") || fail "user configuration changed"
    if [ "$failures" -ne "$before" ]; then
        echo "--- output"; cat "$tmp/out"; echo "--- calls"; cat "$tmp/calls.log" 2>/dev/null || true
    else echo "ok   [$name]"; fi
    if [ -n "${KEEP:-}" ]; then echo "kept $tmp"; else rm -rf "$tmp"; fi
}
want() { case "$name" in *"${ONLY:-}"*) return 0 ;; esac; return 1; }

if [ "$(id -u)" -eq 0 ]; then
    name="as root: a Beta is never built, nothing installed"
    setup 0.2.1beta.2-1 beta v0.2.2-beta
    upd --install --yes; status 1; says "never runs as root"; no_install; installed 0.2.1beta.2-1
    if grep -q '^build' "$tmp/calls.log" 2>/dev/null; then fail "built as root"; fi
    finish
    [ "$failures" -eq 0 ] && { echo "update: OK as root ($scenarios scenario; run as a user for the rest)"; exit 0; } || exit 1
fi

# ---- the package scriptlet (packaging/arch/raywm.install) -------------------

scriptlet() { # <function> <version>
    (RAYWM_UPDATE_CONF="$tmp/etc/raywm/update.conf"; . "$root/packaging/arch/raywm.install"; "$1" "$2") >>"$tmp/out" 2>&1
}

name="1. fresh Beta installation subscribes to beta"
if want; then setup - - ; rm -rf "$tmp/etc"
    scriptlet post_install 0.2.2beta-1; channel beta
    [ "$(stat -c %a "$tmp/etc/raywm/update.conf")" = 644 ] || fail "update.conf mode $(stat -c %a "$tmp/etc/raywm/update.conf")"
    finish; fi

name="2. fresh Stable installation subscribes to stable"
if want; then setup - - ; rm -rf "$tmp/etc"
    scriptlet post_install 0.2.2-1; channel stable; finish; fi

name="6/upgrade: the channel survives Beta -> Stable -> Beta -> Stable package upgrades"
if want; then setup - - ; rm -rf "$tmp/etc"
    scriptlet post_install 0.2.1beta.2-1; channel beta
    for v in 0.2.1-1 0.2.2beta-1 0.2.2-1 0.2.3beta-1 0.2.3-1; do scriptlet post_upgrade "$v"; channel beta; done
    rm -rf "$tmp/etc"; scriptlet post_install 0.2.1-1; channel stable
    for v in 0.2.2beta-1 0.2.2-1 0.2.3beta-1; do scriptlet post_upgrade "$v"; channel stable; done
    # Removing and reinstalling keeps it too (the file is not owned by the package).
    scriptlet post_remove 0.2.3beta-1; scriptlet post_install 0.2.4beta-1; channel stable
    finish; fi

name="upgrade from v0.2.1 (no update.conf yet) initializes it once"
if want; then setup - - ; rm -f "$tmp/etc/raywm/update.conf"
    scriptlet post_upgrade 0.2.2beta-1; channel beta
    scriptlet post_upgrade 0.2.2-1; channel beta; finish; fi

name="the scriptlet never rewrites a malformed update.conf"
if want; then setup - - ; echo 'channel=nightly' >"$tmp/etc/raywm/update.conf"
    scriptlet post_upgrade 0.2.2-1
    grep -qx 'channel=nightly' "$tmp/etc/raywm/update.conf" || fail "malformed file replaced"; finish; fi

# ---- selection --------------------------------------------------------------

name="3. Beta -> newer Beta: built from source as the user, then pacman -U"
if want; then setup 0.2.1beta.2-1 beta v0.2.1-beta.2 v0.2.2-beta v0.2.1:legacy v0.2.0:legacy
    upd --check; status 0; says "^Update available: v0.2.2-beta \(pacman 0.2.2beta-1, beta release, source archive"; no_install
    upd --install --yes; status 0; says "SHA256 verified"; says "Package checked: raywm 0.2.2beta-1 x86_64"
    built v0.2.2-beta; installed 0.2.2beta-1; channel beta
    grep -q "^pacman -U --noconfirm $tmp/cache/run-.*/pkg/raywm-0.2.2beta-1-x86_64.pkg.tar.zst$" "$tmp/calls.log" || fail "pacman -U not run on the built package"
    upd --check; status 2; says "^Up to date"
    finish; fi

name="4/6. Beta -> newer Stable: the ready package, and the subscription stays beta"
if want; then setup 0.2.2beta-1 beta v0.2.2-beta v0.2.2-stable
    upd --check; status 0; says "^Update available: v0.2.2-stable \(pacman 0.2.2-1, stable release, Arch Linux package"
    upd --install --yes; status 0; installed 0.2.2-1; channel beta; says "Channel: beta \(unchanged\)"
    if grep -q '^build' "$tmp/calls.log"; then fail "a Stable release was rebuilt"; fi
    finish; fi

name="6. after Stable, a Beta subscriber gets the next Beta"
if want; then setup 0.2.2-1 beta v0.2.2-beta v0.2.2-stable v0.2.3-beta
    upd --check; status 0; says "^Update available: v0.2.3-beta"; finish; fi

name="5/7. Stable -> newer Stable; a Stable subscriber never gets a Beta"
if want; then setup 0.2.1-1 stable v0.2.1-stable v0.2.2-beta v0.2.2-stable v0.2.3-beta v0.2.3-beta.2
    upd --check; status 0; says "^Update available: v0.2.2-stable"
    upd --install --yes; status 0; installed 0.2.2-1; channel stable
    upd --check --verbose; status 2; says "^Up to date: no newer Stable release"; says "skipped v0.2.3-beta: a Beta, not offered to the stable channel"
    finish; fi

name="7. a Stable subscriber running a Beta build waits for the next Stable"
if want; then setup 0.2.2beta-1 stable v0.2.1-stable v0.2.2-beta v0.2.3-beta
    upd --check; status 2; says "^Up to date"
    upd --install --yes; status 0; says "nothing to install"; no_install; installed 0.2.2beta-1; finish; fi

name="8. vercmp order, not tag strings: 0.2.1beta < 0.2.1beta.2 < 0.2.1 < 0.2.2beta < 0.2.2 < 0.2.10beta"
if want; then setup 0.2.1beta-1 beta v0.2.10-beta v0.2.1-beta v0.2.2-stable v0.2.1-beta.2 v0.2.9-beta.3 v0.2.1-stable v0.2.2-beta
    upd --check; status 0; says "^Update available: v0.2.10-beta \(pacman 0.2.10beta-1"
    finish; fi
name="8b. older releases are never offered (installed 0.2.2-1, beta channel)"
if want; then setup 0.2.2-1 beta v0.2.1-beta v0.2.1-beta.2 v0.2.1-stable v0.2.2-beta v0.2.2-stable
    upd --check; status 2; says "^Up to date"; finish; fi

name="9. no updates, also with only historical releases"
if want; then setup 0.2.1-1 beta v0.2.1:legacy v0.2.0:legacy v0.1.1:legacy v0.1.0:legacy
    upd --check --verbose; status 2; says "^Up to date"; says "ignored v0.2.1: not a beta/stable tag \(historical release\)"; finish; fi

name="pagination: the newest release is on page 2"
if want; then export PAGE2=1; setup 0.2.1beta.2-1 beta v0.2.2-beta; unset PAGE2
    upd --check; status 0; says "^Update available: v0.2.2-beta"; finish; fi

# ---- failures: nothing is installed, the cache is cleaned ------------------

name="10. corrupted archive: SHA256 mismatch, nothing installed"
if want; then setup 0.2.1beta.2-1 beta v0.2.2-beta:corrupt
    upd --install --yes; status 1; says "SHA256 mismatch"; says "Nothing was installed"
    no_install; installed 0.2.1beta.2-1; channel beta
    if grep -q '^build' "$tmp/calls.log" 2>/dev/null; then fail "an unverified archive was built"; fi
    finish; fi

name="10b. corrupted Stable package: nothing installed"
if want; then setup 0.2.1-1 stable v0.2.2-stable:corrupt
    upd --install --yes; status 1; says "SHA256 mismatch"; no_install; installed 0.2.1-1; finish; fi

name="11. missing release asset: that release is ignored, an older one offered"
if want; then setup 0.2.1-1 beta v0.2.2-beta v0.2.3-beta:noasset
    upd --check --verbose; status 0; says "ignored v0.2.3-beta: release asset missing"; says "^Update available: v0.2.2-beta"; finish; fi

name="11b. asset listed but unavailable (404): nothing installed"
if want; then setup 0.2.1-1 stable v0.2.2-stable:gone
    upd --install --yes; status 1; says "download failed"; no_install; installed 0.2.1-1; finish; fi

name="12. invalid metadata (malformed, contradicting, missing, wrong flag): ignored"
if want; then setup 0.2.1-1 beta v0.2.2-beta v0.2.3-beta:badmeta v0.2.4-beta:wrongmeta v0.2.5-beta:nometa v0.2.6-beta:badflag v0.2.7-beta:draft
    upd --check --verbose; status 0
    says "v0.2.3-beta: ignored, metadata is not valid JSON"
    says "v0.2.4-beta: ignored, metadata pacman_version differs from the tag"
    says "ignored v0.2.5-beta: raywm-release.json missing"
    says "ignored v0.2.6-beta: Pre-release flag does not match"
    says "ignored v0.2.7-beta: draft"
    says "^Update available: v0.2.2-beta"
    finish; fi

name="13. GitHub API unavailable, unreachable or answering garbage"
if want; then setup 0.2.1-1 beta v0.2.2-beta
    rm -rf "$tmp/world/api"
    upd --check; status 1; says "cannot list releases"
    mkdir -p "$tmp/world/api"; echo '{"message": "API rate limit exceeded"}' >"$tmp/world/api/releases-1.json"
    upd --check; status 1; says "not valid JSON"
    # A real HTTPS request to a closed local port.
    st=0; env -i PATH="$PATH" HOME="$tmp/home" RAYWM_UPDATE_API="https://127.0.0.1:9/releases?page={page}" \
        RAYWM_UPDATE_CONF="$tmp/etc/raywm/update.conf" RAYWM_UPDATE_PACMAN="$root/tests/update/fake-pacman.sh" \
        RAYWM_UPDATE_CACHE="$tmp/cache" FAKE_DB="$tmp/db" FAKE_LOG="$tmp/calls.log" "$upd" --check >"$tmp/out" 2>&1 || st=$?
    status 1; says "network unavailable"
    finish; fi

name="14. failed Beta compilation: nothing installed"
if want; then setup 0.2.1beta.2-1 beta v0.2.2-beta
    FAKE_ENV="FAKE_BUILD_FAIL=1"; upd --install --yes; FAKE_ENV=
    status 1; says "Beta build failed"; no_install; installed 0.2.1beta.2-1; channel beta; finish; fi

name="15. failed package installation: previous version and channel kept"
if want; then setup 0.2.1-1 beta v0.2.2-stable
    FAKE_ENV="FAKE_PACMAN_FAIL=1"; upd --install --yes; FAKE_ENV=
    status 1; says "pacman -U failed"; installed 0.2.1-1; channel beta; finish; fi

name="16. a package with files outside RayWM's paths is refused"
if want; then setup 0.2.1-1 stable v0.2.2-stable:evilpkg
    upd --install --yes; status 1; says "unexpected path: /etc/raywm/update.conf"; no_install; channel stable; finish; fi

name="--install asks first; non-interactive use needs --yes; --dry-run installs nothing"
if want; then setup 0.2.1beta.2-1 beta v0.2.2-beta
    upd --install; status 1; says "pass --yes"; no_install
    upd --install --dry-run; status 0; says "SHA256 verified"; says "Dry run: would build"; says "Dry run: would run: .*fake-pacman.sh -U "
    no_install; installed 0.2.1beta.2-1
    if grep -q '^build' "$tmp/calls.log" 2>/dev/null; then fail "dry run built"; fi
    finish; fi

# ---- channels -----------------------------------------------------------------

name="17. explicit channel switching; never installs"
if want; then setup 0.2.1-1 beta v0.2.2-beta v0.2.2-stable
    upd --channel; status 0; says "^Channel: beta \(.*/update.conf\)"
    upd --set-channel stable --dry-run; status 0; says "Would write"; channel beta
    upd --set-channel stable; status 0; says "Channel: stable \(was beta\). Nothing was installed"; channel stable; no_install
    [ "$(stat -c %a "$tmp/etc/raywm/update.conf")" = 644 ] || fail "mode after --set-channel"
    upd --check; status 0; says "^Update available: v0.2.2-stable"
    upd --set-channel beta; status 0; channel beta
    upd --check; status 0; says "^Update available: v0.2.2-stable"
    upd --set-channel nightly; status 1; says "unknown channel 'nightly'"; channel beta
    [ -z "$(find "$tmp/etc/raywm" -name '.update.conf.*')" ] || fail "temporary file left"
    finish; fi

name="18. missing, malformed or unreadable channel state"
if want; then setup 0.2.2beta-1 - v0.2.2-stable v0.2.3-beta
    upd --channel; status 0; says "Channel: beta \(no .*update.conf; assumed from the installed version"
    upd --check; status 0; says "^Update available: v0.2.3-beta"
    printf 'channel = stable\nchannel = beta\n' >"$tmp/etc/raywm/update.conf"
    upd --check; status 1; says "update.conf:2: expected 'channel=beta' or 'channel=stable'"; says "--set-channel"
    upd --install --yes; status 1; no_install
    echo '# empty' >"$tmp/etc/raywm/update.conf"
    upd --channel; status 1; says "no 'channel=beta' or 'channel=stable' line"
    printf 'channel=stable\n' >"$tmp/etc/raywm/update.conf"; chmod 000 "$tmp/etc/raywm/update.conf"
    upd --check; status 1; says "cannot read"; chmod 644 "$tmp/etc/raywm/update.conf"
    : >"$tmp/db"; rm "$tmp/etc/raywm/update.conf"
    upd --channel; status 0; says "Channel: stable \(no .* and no installed package; the default\)"
    finish; fi

name="working directories of killed runs are removed, live ones kept"
if want; then setup 0.2.1-1 beta v0.2.2-beta
    # A run killed with SIGKILL/Ctrl+C never cleans up after itself.
    mkdir -p "$tmp/cache/run-999999999-dead" "$tmp/cache/run-$$-alive" "$tmp/cache/other"
    touch "$tmp/cache/run-999999999-dead/partial.tar.gz"
    upd --check; status 0
    [ ! -e "$tmp/cache/run-999999999-dead" ] || fail "stale work directory of a dead process kept"
    [ -d "$tmp/cache/run-$$-alive" ] || fail "work directory of a live process removed"
    [ -d "$tmp/cache/other" ] || fail "unrelated directory removed"
    rm -rf "$tmp/cache/run-$$-alive" "$tmp/cache/other"
    finish; fi

name="--version and --help"
if want; then setup 0.2.2beta-1 beta
    upd --version; status 0; says "^raywm-update [0-9]+\.[0-9]+\.[0-9]+$"; says "^raywm package: 0.2.2beta-1$"
    upd --help; status 0; says "--set-channel NAME"
    upd --bogus; status 1
    upd; status 1
    finish; fi

[ "$failures" -eq 0 ] && echo "update: OK ($scenarios scenarios)" || { echo "update: $failures failure(s) in $scenarios scenarios"; exit 1; }

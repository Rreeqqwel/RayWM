#!/bin/sh
# Keyboard focus navigation with REAL key events (virtual keyboard) and
# REAL clients, inside an isolated headless compositor: key bindings with
# several keyboard layouts, directional focus, the focus cycle, cursor
# warping and the focus border (config/plugins/focus.lua).
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=text] tests/navigation.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "navigation: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
. "$root/tests/support/harness.sh"
PLUGINS="$root/tests/pointer/plugins"
kbd_win="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"

# focused <dump> <view id>: in dump N, exactly this view has focus.
focused() {
    awk -v n="dump $1" '$0 == n {on=1; next} /^dump / {on=0} on' "$tmp/probe.log" | grep -q "^view $2 .* focused=true$" ||
        fail "dump $1: view $2 not focused: $(awk -v n="dump $1" '$0 == n {on=1; next} /^dump / {on=0} on' "$tmp/probe.log" | grep focused=true)"
}
# key <name> [mods...]: press and release a key with modifiers held.
key() {
    k=$1; shift
    args=
    for m in "$@"; do args="$args key $m down"; done
    args="$args key $k down key $k up"
    for m in "$@"; do args="$args key $m up"; done
    echo "$args"
}

# ---- Super+J/K with a non-Latin layout active ------------------------------
n1() {
    name="bindings work with a Russian layout active (us,ru)"
    WIN=$kbd_win DRIVER_ENV="XKB_DEFAULT_LAYOUT=us,ru" FLAGS=-d start "$root/tests/input/managed.lua" 2
    f12=$(key f12 super)
    # Layout 1 (ru) is active: J is Cyrillic_o there.
    # shellcheck disable=SC2046
    drive sleep 300 group 1 $f12 $(key j super) sleep 100 $f12 $(key k super) sleep 100 $f12 key h down key h up sleep 100
    focused 1 3
    focused 2 2
    focused 3 3
    # The binding keys reached no client; plain typing does.
    lacks a "kbd key 36"
    lacks b "kbd key 36"
    has b "kbd key 35 pressed"
    # raywm -d explains the match, and never logs plain typing.
    grep -q 'key: Super+j (keycode 36, layout 1 "Russian") -> binding' "$tmp/raywm.log" || fail "no key trace for Super+J"
    if grep -q "key: .*keycode 35" "$tmp/raywm.log"; then fail "plain typing was logged"; fi
    stop
}

run_scenarios navigation n1

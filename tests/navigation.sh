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
tiled="$root/tests/navigation/tiled.lua"
floating="$root/tests/navigation/floating.lua"
# focus.lua with the pointer warp enabled (copied over the shipped one).
warp_dir=$(mktemp -d)
trap 'rm -rf "$warp_dir"' EXIT
sed 's/^  warp = false,$/  warp = true,/' "$root/config/plugins/focus.lua" >"$warp_dir/focus.lua"
grep -q '^  warp = true,$' "$warp_dir/focus.lua" || { echo "navigation: could not enable warp in focus.lua"; exit 2; }

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

# ---- Super+H/J/K/L with a non-Latin layout active --------------------------
n1() {
    name="bindings work with a Russian layout active (us,ru)"
    WIN=$kbd_win DRIVER_ENV="XKB_DEFAULT_LAYOUT=us,ru" FLAGS=-d start "$tiled" 2
    f12=$(key f12 super)
    # Layout 1 (ru) is active: H is Cyrillic_er, L is Cyrillic_de there.
    # shellcheck disable=SC2046
    drive sleep 300 group 1 $f12 $(key h super) sleep 100 $f12 $(key l super) sleep 100 $f12 key h down key h up sleep 100
    focused 1 3
    focused 2 2
    focused 3 3
    # The binding keys reached no client; plain typing does.
    lacks a "kbd key 35"
    lacks a "kbd key 38"
    lacks b "kbd key 38"
    has b "kbd key 35 pressed"
    # raywm -d explains the match, and never logs plain typing.
    grep -q 'key: Super+h (keycode 35, layout 1 "Russian") -> binding' "$tmp/raywm.log" || fail "no key trace for Super+H"
    if grep -q "key: h (keycode 35" "$tmp/raywm.log"; then fail "plain typing was logged"; fi
    stop
}

# ---- directional focus and the cycle with dwindle ----------------------------
n2() {
    name="dwindle: Super+H/J/K/L and Super+Tab move focus, not windows"
    WIN=$kbd_win start "$tiled" 3
    # A 8,8 628x704 (left); B 644,8 628x348; C 644,364 628x348 (focused).
    f12=$(key f12 super)
    # shellcheck disable=SC2046
    drive sleep 300 $(key k super) $f12 $(key h super) $f12 $(key l super) $f12 $(key j super) $f12 \
        $(key tab super) $f12 $(key tab super shift) $f12 $(key j super) $f12
    focused 1 3   # up from C: B
    focused 2 2   # left: A
    focused 3 3   # right from A: B and C tie, B was focused last
    focused 4 4   # down: C
    focused 5 2   # next (wraps, opening order): A
    focused 6 4   # previous: C
    focused 7 4   # down from C: nothing, focus stays
    expect 7 "view 2 8,8 628x704 focused=false"
    expect 7 "view 3 644,8 628x348 focused=false"
    expect 7 "view 4 644,364 628x348 focused=true"
    for w in a b c; do for k in 15 35 36 37 38; do lacks $w "kbd key $k "; done; done
    # Clients see the focus (xdg activated state).
    grep -q "client: activated" "$tmp/a.log" || fail "A was never activated"
    stop
}

# ---- two outputs ---------------------------------------------------------
n3() {
    name="two outputs: directional focus crosses only in its direction"
    OUTPUTS=2 WIN=$kbd_win start "$floating" 4
    # A 100, B 500, C 900 on the first output; D 1300 on the second (focused).
    f12=$(key f12 super)
    # shellcheck disable=SC2046
    drive sleep 300 $(key h super) $f12 $(key l super) $f12 $(key k super) $(key j super) $f12 $(key tab super) $f12 \
        $(key l super) $(key l super) $f12
    focused 1 5   # left from D (second output): C, nearest to the edge
    focused 2 6   # right from C: D on the second output
    focused 3 6   # up/down: nothing
    focused 4 3   # next from D wraps to the first output's first window
    focused 5 5   # right, right: B, C (stays on the first output while it can)
    stop
}

# ---- pointer warp ------------------------------------------------------------
n4() {
    name="warp: pointer follows keyboard focus, never during a held button"
    PLUGINS="$root/tests/pointer/plugins $warp_dir" WIN=$kbd_win start "$floating" 2
    # A 100..300, B 500..700 (focused); the pointer starts on nothing.
    drive move 900 400 sleep 100 $(key h super) sleep 100 $(key l super) sleep 150
    # Warped to the centres: A then B, each entered at 100,75.

    grep -q "client: ptr enter window at 100,75" "$tmp/a.log" || fail "pointer not warped to A"
    grep -q "client: ptr enter window at 100,75" "$tmp/b.log" || fail "pointer not warped to B"
    # Hold a button in B and move keyboard focus to A: no warp, B keeps
    # the pointer and gets the release.
    # shellcheck disable=SC2046
    drive move 550 150 down left sleep 100 $(key h super) sleep 150 move 560 160 up left sleep 150 $(key f12 super)
    focused 1 2
    last_b=$(grep "client: ptr " "$tmp/b.log" | tail -3 | tr '\n' '|')
    [ "$last_b" = "client: ptr button 272 pressed window|client: ptr motion 60,60|client: ptr button 272 released window|" ] ||
        fail "B: $last_b"
    # (A may also have been entered at startup: it lies under wlroots'
    # initial cursor position, 100,100.)
    [ "$(grep -c 'client: ptr enter window at 100,75' "$tmp/a.log")" -eq 1 ] || fail "pointer warped to A again"
    [ "$(grep 'client: ptr ' "$tmp/a.log" | tail -1)" = "client: ptr leave window" ] || fail "A got the pointer during the held button"
    stop
}

# ---- focus border, checked on screen ------------------------------------------
n5() {
    name="focus border is drawn around the focused window only"
    if ! command -v grim >/dev/null || ! command -v python3 >/dev/null; then
        echo "SKIP [$name] grim or python3 missing"; return 0
    fi
    WIN=$kbd_win start "$tiled" 2
    # A 8,8 628x704; B 644,8 628x704 (focused). Border: 2 px, #5294e2.
    shot() {
        env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" grim -t png "$tmp/$1.png" ||
            fail "grim failed"
    }
    png() { python3 -I "$root/tests/support/png_check.py" "$@" >"$tmp/png.out" 2>&1 || fail "$(cat "$tmp/png.out")"; }
    drive sleep 300
    shot 1
    png "$tmp/1.png" --size 1280x720 --pixel 643,300,5294e2 --pixel 642,300,5294e2 --pixel 900,6,5294e2 \
        --pixel 641,300,000000 --pixel 637,300,000000 --pixel 7,300,000000 --pixel 300,7,000000
    drive $(key h super) sleep 200
    shot 2
    png "$tmp/2.png" --pixel 7,300,5294e2 --pixel 300,7,5294e2 --pixel 637,300,5294e2 \
        --pixel 643,300,000000 --pixel 900,6,000000
    stop
}

# ---- reload ----------------------------------------------------------------
n6() {
    name="reload during a held button: grab, bindings and border survive"
    WIN=$kbd_win start "$tiled" 2
    # Hold a button in A while Ctrl+Alt+R reloads every plugin.
    drive_bg move 300 300 down left sleep 1500 move 900 300 sleep 200 up left sleep 200
    sleep 0.5
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 300
    drive_wait
    # A got the motion (outside it, over B) and the release.
    has a "ptr motion 892,292"
    has a "ptr button 272 released window"
    [ "$(grep -c "loaded plugin focus (6 key bindings)" "$tmp/raywm.log")" -eq 2 ] || fail "focus.lua not loaded twice with 6 bindings"
    if grep -q "already bound\|no plugin registered" "$tmp/raywm.log"; then fail "binding warnings after reload"; fi
    # Bindings work once each after the reload (A was clicked: focused).
    drive sleep 200 $(key l super) $(key f12 super) $(key h super) $(key f12 super)
    focused 1 3
    focused 2 2
    stop
}

# ---- an exclusive layer surface (launcher) holds the keyboard ----------------
n7() {
    name="launcher open: focus keys still work, keyboard and pointer stay"
    PLUGINS="$root/tests/pointer/plugins $warp_dir" WIN=$kbd_win start "$floating" 2 panel-kbd
    drive move 900 400 sleep 300 $(key h super) $(key f12 super) key q down key q up sleep 150
    focused 1 2
    # The launcher keeps the keyboard; no warp while it is open.
    has panel "kbd key 16 pressed"
    lacks a "kbd key 16"
    lacks a "ptr enter window at 100,75"
    stop
}

# ---- closing the focused window while its button is held ----------------------
n8() {
    name="Super+Q closes the window whose button is held"
    WIN="$kbd_win RAYWM_TEST_CLOSE=1" start "$floating" 2
    drive_bg move 150 150 down left sleep 1200 move 600 150 sleep 600 up left sleep 200 move 610 150 sleep 100
    sleep 0.5
    drive $(key q super) sleep 200
    wait_log a "closing"
    sleep 0.3   # over B now, the button still held
    if grep -q "client: ptr" "$tmp/b.log"; then fail "B got pointer events while the button was held"; fi
    drive_wait
    stream_b=$(grep "client: ptr" "$tmp/b.log" | tr '\n' '|')
    [ "$stream_b" = "client: ptr enter window at 100,50|client: ptr motion 110,50|" ] || fail "B: $stream_b"
    drive $(key f12 super) move 600 150 down left up left sleep 150
    expect 1 "view 3 500,100 200x150 focused=true"
    has b "ptr button 272 released window"
    stop
}

# ---- existing v0.1.1 configurations -----------------------------------------
n9() {
    name="an unchanged v0.1.1 config keeps its Super+J/K (dwindle order)"
    PLUGINS="$root/tests/compat/v0.1.1/plugins" WIN=$kbd_win start "$root/tests/compat/v0.1.1/init.lua" 3
    f12=$(key f12 super)
    # shellcheck disable=SC2046
    drive sleep 300 $(key j super) $f12 $(key k super) $f12
    focused 1 2   # next in tree order from C wraps to A
    focused 2 4   # previous: C
    if grep -q "already bound\|no plugin registered" "$tmp/raywm.log"; then fail "warnings with the old config"; fi
    stop
}

n10() {
    name="old dwindle.lua plus the new focus.lua: the clash is reported"
    PLUGINS="$root/tests/compat/v0.1.1/plugins" WIN=$kbd_win start "$root/tests/compat/v0.1.1/mixed.lua" 2
    grep -q "plugin focus: key Super+j is already bound by plugin dwindle, whose binding is used" "$tmp/raywm.log" ||
        fail "no duplicate binding warning"
    [ "$(grep -c "already bound" "$tmp/raywm.log")" -eq 1 ] || fail "more than one warning for one plugin"
    # Super+H/L (not bound by the old dwindle) work.
    drive sleep 300 $(key h super) $(key f12 super)
    focused 1 2
    stop
}

run_scenarios navigation n1 n2 n3 n4 n5 n6 n7 n8 n9 n10

#!/bin/sh
# Wayland protocols with real clients in an isolated headless compositor:
# requests are made and the compositor's answers checked, not only the
# globals. Clipboard and primary selection through data control
# (wl-clipboard, cliphist), fractional scale, single-pixel buffers and
# viewports, presentation feedback, cursor shapes, security-context.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
# and wl-clipboard, cliphist, wlr-randr, grim, python3.
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/protocols.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-probe" ] || { echo "protocols: missing $bin/raywm-test-probe (build with -Dtest-input)"; exit 2; }
for t in wl-copy wl-paste cliphist wlr-randr grim python3; do
    command -v "$t" >/dev/null || { echo "protocols: $t is required"; exit 2; }
done
. "$root/tests/support/harness.sh"

cfg="$root/tests/protocols/init.lua"
floating="$root/tests/protocols/floating.lua"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"

tool() {
    n=$1; shift
    env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" "$@" >>"$tmp/$n.log" 2>&1
}
bg_tool() {
    n=$1; shift
    env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" "$@" >>"$tmp/$n.log" 2>&1 &
    echo $! >"$tmp/$n.pid"
}
png() { python3 -I "$root/tests/support/png_check.py" "$@" >"$tmp/png.out" 2>&1 || fail "$(cat "$tmp/png.out")"; }
no_windows() {
    if awk '/^dump /{d=$2} d && /^view /{found=1} END {exit !found}' "$tmp/probe.log"; then fail "a window was mapped: $(grep '^view ' "$tmp/probe.log")"; fi
}

p1() {
    name="clipboard and primary selection without a window (data control)"
    start "$cfg" 0
    echo hello | tool copy wl-copy || fail "wl-copy failed"
    [ "$(tool paste wl-paste --no-newline; cat "$tmp/paste.log")" = "hello" ] || fail "wl-paste: '$(cat "$tmp/paste.log")'"
    echo prim | tool copyp wl-copy --primary || fail "wl-copy --primary failed"
    tool pastep wl-paste --primary --no-newline
    [ "$(cat "$tmp/pastep.log")" = "prim" ] || fail "wl-paste --primary: '$(cat "$tmp/pastep.log")'"
    dump                                                                      # 1
    no_windows
    stop
}

p2() {
    name="a clipboard manager (cliphist) records copies"
    start "$cfg" 0
    bg_tool watch wl-paste --watch cliphist store
    sleep 0.5
    printf 'from the test\n' | tool copy wl-copy
    sleep 0.5
    tool list cliphist list
    grep -q "from the test" "$tmp/list.log" || fail "cliphist did not record the copy: $(cat "$tmp/list.log")"
    kill "$(cat "$tmp/watch.pid")" 2>/dev/null || true
    stop
}

p3() {
    name="fractional scale: clients get their output's scale"
    WIN="$plain RAYWM_TEST_FRACTIONAL=1" start "$cfg" 1
    wait_log a "fractional scale 120"
    tool randr wlr-randr --output HEADLESS-1 --scale 1.5 || fail "wlr-randr failed"
    wait_log a "fractional scale 180"
    stop
}

p4() {
    name="a single-pixel buffer scaled by a viewport fills the window"
    WIN="$plain RAYWM_TEST_SINGLE_PIXEL=00ff00" start "$floating" 1
    dump                                                                      # 1
    expect 1 "view 2 540,285 200x150 focused=true"
    tool shot grim "$tmp/shot.png" || fail "grim failed"
    png "$tmp/shot.png" --pixel 545,290,00ff00 --pixel 735,430,00ff00 --pixel 530,280,000000
    stop
}

p5() {
    name="presentation feedback: shown updates are presented, replaced ones discarded"
    # Floating: the first buffer is shown as it is.
    WIN="$plain RAYWM_TEST_PRESENTATION=1" start "$floating" 1
    wait_log a "presented refresh"
    stop
    # Tiled: the first buffer (its own size) is replaced by the tile-size
    # one before the window is revealed, so it is never displayed.
    WIN="$plain RAYWM_TEST_PRESENTATION=1" start "$cfg" 1
    wait_log a "presentation discarded"
    lacks a "presented refresh"
    stop
}

p6() {
    name="a cursor shape from the client that has the pointer"
    FLAGS=-d WIN="$plain RAYWM_TEST_CURSOR_SHAPE=1" start "$floating" 1
    drive move 600 330 sleep 200
    wait_log a "cursor shape set"
    sleep 0.2
    grep -q "debug(protocols): cursor shape grab" "$tmp/raywm.log" || fail "the compositor did not apply the shape"
    stop
}

p7() {
    name="sandboxed clients (security-context) do not see privileged globals"
    start "$cfg" 0
    tool sb "$bin/raywm-test-probe" sandbox || fail "probe failed: $(cat "$tmp/sb.log")"
    for g in wl_compositor xdg_wm_base wl_seat wp_viewporter; do
        grep -qx "probe: sandboxed sees $g" "$tmp/sb.log" || fail "sandboxed client misses $g"
    done
    for g in zwlr_screencopy_manager_v1 zwlr_data_control_manager_v1 ext_data_control_manager_v1 zwlr_output_manager_v1 \
        ext_session_lock_manager_v1 zwlr_layer_shell_v1 wp_security_context_manager_v1 zwlr_gamma_control_manager_v1 \
        zwp_virtual_keyboard_manager_v1; do
        if grep -qx "probe: sandboxed sees $g" "$tmp/sb.log"; then fail "sandboxed client sees $g"; fi
    done
    grep -qx "probe: normal sees zwlr_screencopy_manager_v1" "$tmp/sb.log" || fail "an ordinary client lost screencopy"
    stop
}

run_scenarios protocols p1 p2 p3 p4 p5 p6 p7

#!/bin/sh
# Session infrastructure with real clients in an isolated headless
# compositor: ext-session-lock-v1 (a test locker and real swaylock), idle
# notification (real swayidle) and idle inhibitors.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
# and grim, swaylock, swayidle, python3.
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/session.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-lock" ] || { echo "session: missing $bin/raywm-test-lock (build with -Dtest-input)"; exit 2; }
for tool in grim swaylock swayidle python3; do
    command -v "$tool" >/dev/null || { echo "session: $tool is required"; exit 2; }
done
. "$root/tests/support/harness.sh"

cfg="$root/tests/session/init.lua"
plugins="$root/tests/session/plugins"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
# Opaque quadrants: red top-left, green top-right, blue bottom-left, white.
pattern="$plain RAYWM_TEST_PATTERN=1"
super_key() { drive key super down key "$1" down key "$1" up key super up sleep 300; }

# client <name> <program> <args...>: a client of the test compositor.
client() {
    n=$1; shift
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" "$@" >"$tmp/$n.log" 2>&1 &
    echo $! >"$tmp/$n.pid"
}
locker() { n=$1; shift; client "$n" "$@" "$bin/raywm-test-lock"; }
shot() {
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" grim "$@" >>"$tmp/grim.log" 2>&1 ||
        fail "grim $*"
}
png() { python3 -I "$root/tests/support/png_check.py" "$@" >"$tmp/png.out" 2>&1 || fail "$(cat "$tmp/png.out")"; }
alive() { kill -0 "$pid" 2>/dev/null || fail "raywm is gone"; }

s1() {
    name="locked: only the locker is drawn and gets input; no binding runs"
    WIN=$pattern PLUGINS=$plugins start "$cfg" 1
    shot "$tmp/before.png"
    png "$tmp/before.png" --pixel 100,100,ff0000                # the window's red quadrant
    drive sleep 300 key j down key j up sleep 150             # the window has the keyboard
    presses a 1
    locker l
    wait_log l "locked"
    sleep 0.2
    shot "$tmp/locked.png"
    png "$tmp/locked.png" --size 1280x720 --pixel 100,100,00ff00 --pixel 640,360,00ff00 --pixel 1200,650,00ff00
    awk '/client: kbd key 36 pressed/ {k = NR} /client: kbd leave/ && k {l = NR} END {exit !l}' "$tmp/a.log" ||
        fail "the window was not told it lost the keyboard"
    # Keys and clicks reach the locker only; Super+Shift+E (quit) and the
    # probe's Super+F12 do nothing.
    drive sleep 300 key j down key j up sleep 150
    drive key super down key shift down key e down key e up key shift up key super up sleep 300
    drive move 300 300 down left up left sleep 150
    alive
    grep -q "lock: kbd key 36 pressed" "$tmp/l.log" || fail "the locker got no key"
    grep -q "lock: ptr button 272 pressed" "$tmp/l.log" || fail "the locker got no click"
    presses a 1
    lacks a "ptr button 272"
    grep -qx "lock locked=true focus_kept=true" "$tmp/locktest.log" || fail "a plugin moved focus while locked"
    grep -qx "warp nil locked" "$tmp/locktest.log" || fail "the pointer was warped while locked"
    # F12 unlocks: the window is back, with the keyboard.
    drive sleep 300 key f12 down key f12 up sleep 300
    wait_log l "unlocked"
    sleep 0.2
    shot "$tmp/after.png"
    png "$tmp/after.png" --pixel 100,100,ff0000
    grep -qx "unlock locked=false" "$tmp/locktest.log" || fail "no unlock event"
    drive sleep 300 key j down key j up sleep 150
    presses a 2
    stop
}

s2() {
    name="a locker that crashes leaves the session locked; a new one unlocks it"
    WIN=$pattern PLUGINS=$plugins start "$cfg" 1
    locker l RAYWM_TEST_LOCK_CRASH=1
    wait_log l "crashing"
    sleep 0.3
    shot "$tmp/abandoned.png"
    png "$tmp/abandoned.png" --pixel 100,100,590000 --pixel 640,360,590000   # dark red, no window
    grep -q "exited without unlocking" "$tmp/raywm.log" || fail "no warning about the dead locker"
    drive sleep 300 key j down key j up sleep 150
    lacks a "kbd key 36 pressed"
    locker m
    wait_log m "locked"
    sleep 0.2
    shot "$tmp/relocked.png"
    png "$tmp/relocked.png" --pixel 100,100,00ff00
    drive sleep 300 key f12 down key f12 up sleep 300
    wait_log m "unlocked"
    sleep 0.2
    shot "$tmp/after.png"
    png "$tmp/after.png" --pixel 100,100,ff0000
    stop
}

s3() {
    name="a second locker is refused while one holds the lock"
    WIN=$plain PLUGINS=$plugins start "$cfg" 1
    locker l
    wait_log l "locked"
    locker m
    wait_log m "finished"
    lacks m "lock: locked"
    drive sleep 300 key f12 down key f12 up sleep 300
    wait_log l "unlocked"
    stop
}

s4() {
    name="two outputs, and outputs plugged in and unplugged while locked"
    OUTPUTS=2 WIN=$pattern PLUGINS=$plugins start "$cfg" 1
    locker l
    wait_log l "locked"
    [ "$(grep -c 'surface configured 1280x720' "$tmp/l.log")" -eq 2 ] || fail "expected two lock surfaces"
    sleep 0.2
    shot "$tmp/both.png"
    png "$tmp/both.png" --size 2560x720 --pixel 100,100,00ff00 --pixel 1380,100,00ff00 --pixel 2400,600,00ff00
    plug
    sleep 0.5
    [ "$(grep -c 'surface configured 1280x720' "$tmp/l.log")" -eq 3 ] || fail "no lock surface for the new output"
    shot "$tmp/three.png"
    png "$tmp/three.png" --size 3840x720 --pixel 2660,100,00ff00
    unplug HEADLESS-1
    sleep 0.4
    alive
    drive sleep 300 key f12 down key f12 up sleep 300
    wait_log l "unlocked"
    stop
}

s5() {
    name="swaylock locks the session; killing it keeps the session locked"
    WIN=$pattern PLUGINS=$plugins start "$cfg" 1
    client sw swaylock -c 0000ff
    i=0
    until grep -q "lock locked=true" "$tmp/locktest.log" 2>/dev/null; do
        i=$((i + 1)); [ $i -gt 60 ] && { fail "swaylock did not lock"; break; }; sleep 0.05
    done
    sleep 0.5
    shot "$tmp/swaylock.png"
    png "$tmp/swaylock.png" --pixel 100,100,0000ff --pixel 1200,650,0000ff
    kill -9 "$(cat "$tmp/sw.pid")"
    sleep 0.4
    shot "$tmp/killed.png"
    png "$tmp/killed.png" --pixel 100,100,590000
    locker l
    wait_log l "locked"
    drive sleep 300 key f12 down key f12 up sleep 300
    wait_log l "unlocked"
    sleep 0.2
    shot "$tmp/after.png"
    png "$tmp/after.png" --pixel 100,100,ff0000
    stop
}

s6() {
    name="idle: swayidle times out without input; a visible idle inhibitor holds it"
    WIN=$plain PLUGINS=$plugins start "$cfg" 1
    client si swayidle -w timeout 1 "touch '$tmp/idle'" resume "touch '$tmp/resumed'"
    sleep 1.8
    [ -e "$tmp/idle" ] || fail "no idle notification after 1 s without input"
    drive move 200 200 sleep 300
    [ -e "$tmp/resumed" ] || fail "no resume after input"
    kill "$(cat "$tmp/si.pid")"
    rm -f "$tmp/idle" "$tmp/resumed"
    # A window with an idle inhibitor, visible: no idle notification ...
    launch b $plain RAYWM_TEST_IDLE_INHIBIT=1
    wait_log b "idle inhibitor created"
    client si swayidle -w timeout 1 "touch '$tmp/idle'"
    sleep 1.8
    [ ! -e "$tmp/idle" ] || fail "idle although a visible window inhibits it"
    # ... until it is hidden (another workspace).
    super_key 2
    sleep 1.8
    [ -e "$tmp/idle" ] || fail "a hidden window's inhibitor still held back idle"
    kill "$(cat "$tmp/si.pid")"
    stop
}

s7() {
    name="autostart: once per start, not again on reload; new commands at the next reload"
    start "$root/tests/session/autostart.lua" 0
    # The shipped plugin with two commands (and later a third).
    sed 's|^  commands = {$|  commands = { "echo a >>'"'$tmp/auto'"'", "echo b >>'"'$tmp/auto'"'",|' \
        "$root/config/plugins/autostart.lua" >"$tmp/config/raywm/plugins/autostart.lua"
    reload() { drive key super down key shift down key r down key r up key shift up key super up sleep 500; }
    reload
    # spawn_once starts asynchronous processes; completion order is not
    # the order of the synchronous Lua startup callbacks.
    [ "$(sort "$tmp/auto" 2>/dev/null)" = "$(printf 'a\nb')" ] || fail "commands did not run once: $(cat "$tmp/auto" 2>/dev/null)"
    reload
    [ "$(wc -l <"$tmp/auto")" -eq 2 ] || fail "a reload started them again"
    sed -i 's|^  commands = { |  commands = { "echo c >>'"'$tmp/auto'"'", |' "$tmp/config/raywm/plugins/autostart.lua"
    reload
    [ "$(sort "$tmp/auto")" = "$(printf 'a\nb\nc')" ] || fail "the new command did not start once: $(cat "$tmp/auto")"
    stop
}

s8() {
    name="shutdown while actively locked releases native backgrounds before scene destruction"
    PLUGINS=$plugins start "$cfg" 1
    locker l
    wait_log l "locked"
    stop
}
s9() {
    name="shutdown after locker death releases the abandoned lock backgrounds"
    PLUGINS=$plugins start "$cfg" 1
    locker l RAYWM_TEST_LOCK_CRASH=1
    wait_log l "crashing"
    sleep 0.2
    grep -q 'exited without unlocking' "$tmp/raywm.log" || fail "no abandoned lock"
    stop
}
run_scenarios session s1 s2 s3 s4 s5 s6 s7 s8 s9

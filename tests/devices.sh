#!/bin/sh
# Input devices with virtual input in an isolated headless compositor:
# key repeat settings reaching clients, a layout that does not compile,
# device events, keyboard layout switching. (libinput pointer and
# touchpad settings need real devices: docs/TESTING.md, manual plan.)
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/devices.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "devices: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
. "$root/tests/support/harness.sh"

cfg="$root/tests/devices/init.lua"
plugins="$root/tests/devices/plugins"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"

d1() {
    name="key repeat settings reach clients; virtual devices are listed"
    WIN=$plain PLUGINS=$plugins start "$cfg" 1
    drive sleep 300 key j down key j up sleep 150
    grep -qx "configure true" "$tmp/devtest.log" || fail "configure failed"
    has a "kbd repeat 40 300"
    grep -q "^add keyboard .* virtual=true" "$tmp/devtest.log" || fail "no input_add for the virtual keyboard: $(cat "$tmp/devtest.log")"
    grep -q "^add pointer " "$tmp/devtest.log" || fail "no input_add for the virtual pointer"
    grep -qx "remove" "$tmp/devtest.log" || fail "no input_remove when the driver left"
    stop
}

d2() {
    name="a layout that does not compile is refused; the keyboard keeps working"
    WIN=$plain PLUGINS=$plugins start "$cfg" 1
    drive key super down key f9 down key f9 up key super up sleep 300
    grep -qx "badlayout nil bad_keymap" "$tmp/devtest.log" || fail "the bad layout was not refused: $(cat "$tmp/devtest.log")"
    drive sleep 300 key j down key j up sleep 150
    presses a 1
    stop
}

d3() {
    name="keyboard layouts: switching from Lua and from the keyboard"
    WIN=$plain PLUGINS=$plugins DRIVER_ENV="XKB_DEFAULT_LAYOUT=us,ru" start "$cfg" 1
    drive key super down key f10 down key f10 up key super up sleep 300
    grep -qx "setlayout true active=2 names=English (US),Russian" "$tmp/devtest.log" || fail "set layout: $(cat "$tmp/devtest.log")"
    grep -qx "layout 2" "$tmp/devtest.log" || fail "no keyboard_layout event"
    # The driver's own group switch (a layout toggle key) is seen too.
    drive group 1 sleep 200 group 0 sleep 200
    [ "$(grep -c '^layout ' "$tmp/devtest.log")" -ge 3 ] || fail "layout changes from the keyboard not reported: $(cat "$tmp/devtest.log")"
    stop
}

run_scenarios devices d1 d2 d3

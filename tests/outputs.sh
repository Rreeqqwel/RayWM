#!/bin/sh
# Outputs with real clients in an isolated headless compositor: wlr-randr
# (wlr-output-management), outputs.lua, raywm.output_configure, hotplug,
# disabling and enabling outputs with their workspaces, fullscreen and
# panels following a mode change, output power (DPMS) and gamma control.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
# and wlr-randr.
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/outputs.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-probe" ] || { echo "outputs: missing $bin/raywm-test-probe (build with -Dtest-input)"; exit 2; }
command -v wlr-randr >/dev/null || { echo "outputs: wlr-randr is required"; exit 2; }
. "$root/tests/support/harness.sh"

cfg="$root/tests/outputs/init.lua"
helpers="$root/tests/outputs/plugins"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
super_key() { drive key super down key "$1" down key "$1" up key super up sleep 300; }
# One output: id 1, workspaces 2..10, windows from 11. Two outputs:
# HEADLESS-2 (left) id 1, HEADLESS-1 (right) id 2, workspaces 3..20,
# windows from 21.

tool() {
    n=$1; shift
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" "$@" >>"$tmp/$n.log" 2>&1
}
randr() { tool randr wlr-randr "$@" || fail "wlr-randr $* failed"; sleep 0.4; }
probe() { tool probe "$bin/raywm-test-probe" "$@" || fail "probe $* failed"; }

o1() {
    name="wlr-randr: mode, scale, rotation and position; windows are tiled again"
    WIN=$plain PLUGINS=$helpers start "$cfg" 1
    dump                                                                      # 1
    expect 1 "output HEADLESS-1 0,0 1280x720 scale=1.0 transform=normal enabled=true power=true mode=1280x720 usable=0,0 1280x720"
    randr --output HEADLESS-1 --custom-mode 1600x900
    dump                                                                      # 2
    expect 2 "output HEADLESS-1 0,0 1600x900 scale=1.0 transform=normal enabled=true power=true mode=1600x900 usable=0,0 1600x900"
    expect 2 "view 11 8,8 1584x884 focused=true"
    randr --output HEADLESS-1 --scale 2
    dump                                                                      # 3
    expect 3 "output HEADLESS-1 0,0 800x450 scale=2.0 transform=normal enabled=true power=true mode=1600x900 usable=0,0 800x450"
    expect 3 "view 11 8,8 784x434 focused=true"
    wait_log a "output scale 2"
    randr --output HEADLESS-1 --transform 90
    dump                                                                      # 4
    expect 4 "output HEADLESS-1 0,0 450x800 scale=2.0 transform=90 enabled=true power=true mode=1600x900 usable=0,0 450x800"
    expect 4 "view 11 8,8 434x784 focused=true"
    randr --output HEADLESS-1 --pos 100,50
    dump                                                                      # 5
    expect 5 "view 11 108,58 434x784 focused=true"
    stop
}

o2() {
    name="disabling an output moves its workspaces; enabling it sends them home"
    OUTPUTS=2 WIN=$plain PLUGINS=$helpers start "$cfg" 0
    drive move 1900 360
    launch a $plain
    wait_log a "frame done"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "where 21 1@HEADLESS-1"
    expect 1 "state 21 floating=false fullscreen=false maximized=false visible=true managed=true ws=12 output=2"
    randr --output HEADLESS-1 --off
    dump                                                                      # 2
    expect 2 "output HEADLESS-1 0,0 0x0 scale=1.0 transform=normal enabled=false power=false mode=1280x720 usable=0,0 0x0"
    expect 2 "ws 1@HEADLESS-1 output=HEADLESS-2 active=false orphan=false"
    expect 2 "state 21 floating=false fullscreen=false maximized=false visible=false managed=true ws=12 output=1"
    randr --output HEADLESS-1 --on
    dump                                                                      # 3
    expect 3 "output HEADLESS-1 1280,0 1280x720 scale=1.0 transform=normal enabled=true power=true mode=1280x720 usable=1280,0 1280x720"
    expect 3 "output HEADLESS-2 0,0 1280x720 scale=1.0 transform=normal enabled=true power=true mode=1280x720 usable=0,0 1280x720"
    expect 3 "ws 1@HEADLESS-1 output=HEADLESS-1 active=true orphan=false"
    expect 3 "state 21 floating=false fullscreen=false maximized=false visible=true managed=true ws=12 output=2"
    expect 3 "view 21 1288,8 1264x704 focused=false"
    stop
}

o3() {
    name="the last output cannot be disabled; bad settings change nothing"
    WIN=$plain PLUGINS=$helpers start "$cfg" 1
    if tool randr wlr-randr --output HEADLESS-1 --off; then fail "disabling the only output succeeded"; fi
    drive key super down key f9 down key f9 up key super up sleep 300
    dump                                                                      # 1
    expect 1 "output HEADLESS-1 0,0 1280x720 scale=1.0 transform=normal enabled=true power=true mode=1280x720 usable=0,0 1280x720"
    expect 1 "view 11 8,8 1264x704 focused=true"
    for want in "true nil bad_scale" "true nil bad_transform" "true nil stale" "true nil no_output_left" "true nil bad_mode"; do
        grep -qxF "$want" "$tmp/outhelpers.log" || fail "no '$want' in $(tr '\n' '|' <"$tmp/outhelpers.log")"
    done
    grep -q "^false .*mode must look like" "$tmp/outhelpers.log" || fail "a malformed mode string is not an error"
    stop
}

o4() {
    name="outputs.lua configures outputs at startup and when they are plugged in"
    # The shipped plugin with two entries.
    pl=$(mktemp -d)
    sed 's|^local outputs = {$|local outputs = { { name = "HEADLESS-1", mode = "1600x900", scale = 2 }, { name = "HEADLESS-2", transform = "90" },|' \
        "$root/config/plugins/outputs.lua" >"$pl/outputs.lua"
    WIN=$plain PLUGINS="$helpers $pl" start "$cfg" 1
    rm -rf "$pl"
    dump                                                                      # 1
    expect 1 "output HEADLESS-1 0,0 800x450 scale=2.0 transform=normal enabled=true power=true mode=1600x900 usable=0,0 800x450"
    expect 1 "view 11 8,8 784x434 focused=true"
    plug
    sleep 0.5
    dump                                                                      # 2
    expect 2 "output HEADLESS-2 800,0 720x1280 scale=1.0 transform=90 enabled=true power=true mode=1280x720 usable=800,0 720x1280"
    stop
}

o5() {
    name="a fullscreen window and a panel's exclusive zone follow a mode change"
    WIN=$plain PLUGINS=$helpers start "$cfg" 1 panel
    super_key f
    randr --output HEADLESS-1 --custom-mode 1600x900
    dump                                                                      # 1
    expect 1 "view 11 0,0 1600x900 focused=true"
    super_key f
    dump                                                                      # 2
    expect 2 "view 11 8,38 1584x854 focused=true"
    expect 2 "output HEADLESS-1 0,0 1600x900 scale=1.0 transform=normal enabled=true power=true mode=1600x900 usable=0,30 1600x870"
    stop
}

o6() {
    name="DPMS keeps a powered-off output in the layout; gamma control answers"
    WIN=$plain PLUGINS=$helpers start "$cfg" 1
    probe power HEADLESS-1 off
    grep -q "probe: power mode off" "$tmp/probe.log" || fail "no power off: $(cat "$tmp/probe.log")"
    dump                                                                      # 1
    expect 1 "output HEADLESS-1 0,0 1280x720 scale=1.0 transform=normal enabled=true power=false mode=1280x720 usable=0,0 1280x720"
    expect 1 "state 11 floating=false fullscreen=false maximized=false visible=true managed=true ws=2 output=1"
    probe power HEADLESS-1 on
    grep -q "probe: power mode on" "$tmp/probe.log" || fail "no power on: $(cat "$tmp/probe.log")"
    dump                                                                      # 2
    expect 2 "output HEADLESS-1 0,0 1280x720 scale=1.0 transform=normal enabled=true power=true mode=1280x720 usable=0,0 1280x720"
    # Headless outputs have no gamma ramp: the protocol answers "failed".
    probe gamma HEADLESS-1
    grep -qE "probe: gamma (failed|size [0-9]+)" "$tmp/probe.log" || fail "no gamma answer: $(cat "$tmp/probe.log")"
    stop
}

o7() {
    name="enabling an output from Lua puts it back where it was; the others stay"
    OUTPUTS=2 WIN=$plain PLUGINS=$helpers start "$cfg" 0
    drive key super down key f10 down key f10 up key super up sleep 400      # off
    drive key super down key f10 down key f10 up key super up sleep 400      # on
    grep -qx "disable true nil" "$tmp/outhelpers.log" || fail "disabling failed: $(cat "$tmp/outhelpers.log")"
    grep -qx "enable true nil" "$tmp/outhelpers.log" || fail "enabling failed: $(cat "$tmp/outhelpers.log")"
    dump                                                                      # 1
    expect 1 "output HEADLESS-2 0,0 1280x720 scale=1.0 transform=normal enabled=true power=true mode=1280x720 usable=0,0 1280x720"
    expect 1 "output HEADLESS-1 1280,0 1280x720 scale=1.0 transform=normal enabled=true power=true mode=1280x720 usable=1280,0 1280x720"
    stop
}

run_scenarios outputs o1 o2 o3 o4 o5 o6 o7

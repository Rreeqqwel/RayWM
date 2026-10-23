#!/bin/sh
# Window rules (config/plugins/window-rules.lua and a rules.lua) with real
# clients in an isolated headless compositor: dialogs, fixed-size windows,
# floating with size and position, workspace, focus, fullscreen.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/rules.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "rules: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
. "$root/tests/support/harness.sh"

cfg="$root/tests/rules/init.lua"
rules="$root/tests/rules/rules.lua"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
# One output (id 1), workspaces 2..10, windows from 11.

shown_after_resize() {
    awk -v r="client: hold resized $2" '$0 == r && !rs {rs = NR} /client: surface enter/ && !en {en = NR} END {exit !(rs && en && rs < en)}' "$tmp/$1.log" ||
        fail "$1 was shown before it had its size $2"
}

r1() {
    name="a dialog floats, centred over its parent, which stays tiled"
    WIN="$plain RAYWM_TEST_CHILD=1" RULES=$rules start "$cfg" 1
    wait_log a "child mapped"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "view 11 8,8 1264x704 focused=false"
    expect 1 "view 12 580,315 120x90 focused=true"
    expect 1 "state 12 floating=true fullscreen=false maximized=false visible=true managed=false ws=2 output=1"
    stop
}

r2() {
    name="a small fixed-size window floats; a screen-sized one is tiled"
    RULES=$rules start "$cfg" 0
    launch a $plain RAYWM_TEST_MIN=300x200 RAYWM_TEST_MAX=300x200 RAYWM_TEST_SIZE=300x200
    wait_log a "frame done"
    launch b $plain RAYWM_TEST_MIN=1280x720 RAYWM_TEST_MAX=1280x720 RAYWM_TEST_SIZE=1280x720
    wait_log b "round 0 configured"
    sleep 0.4
    dump                                                                      # 1
    expect 1 "state 11 floating=true fullscreen=false maximized=false visible=true managed=false ws=2 output=1"
    expect 1 "view 11 490,260 300x200 focused=false"
    expect 1 "state 12 floating=false fullscreen=false maximized=false visible=true managed=true ws=2 output=1"
    stop
}

r3() {
    name="a rule floats a window at a size and position; it appears there"
    RULES=$rules start "$cfg" 0
    launch a $plain RAYWM_TEST_APP_ID=float-me
    wait_log a "surface enter"
    sleep 0.2
    shown_after_resize a 400x300
    dump                                                                      # 1
    expect 1 "view 11 10,20 400x300 focused=true"
    expect 1 "state 11 floating=true fullscreen=false maximized=false visible=true managed=false ws=2 output=1"
    # Percentages of the usable area, centred.
    launch b $plain RAYWM_TEST_APP_ID=half
    wait_log b "surface enter"
    sleep 0.2
    dump                                                                      # 2
    expect 2 "view 12 320,180 640x360 focused=true"
    stop
}

r4() {
    name="rules: a workspace of its own, and not taking the keyboard"
    WIN=$plain RULES=$rules start "$cfg" 1
    launch b $plain RAYWM_TEST_APP_ID=ws3
    wait_log b "round 0 configured"
    sleep 0.3
    launch c $plain RAYWM_TEST_APP_ID=quiet
    wait_log c "frame done"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "where 12 3@HEADLESS-1"
    expect 1 "state 12 floating=false fullscreen=false maximized=false visible=false managed=true ws=4 output=1"
    lacks b "surface enter"
    expect 1 "view 11 8,8 628x704 focused=true"
    expect 1 "view 13 644,8 628x704 focused=false"
    lacks c "client: activated"
    stop
}

r5() {
    name="rules: fullscreen at open; float = false overrides the dialog test"
    RULES=$rules start "$cfg" 0
    launch a $plain RAYWM_TEST_TITLE=fs-me
    wait_log a "fullscreen on"
    sleep 0.3
    launch b $plain RAYWM_TEST_APP_ID=tile-me RAYWM_TEST_MIN=300x200 RAYWM_TEST_MAX=300x200 RAYWM_TEST_SIZE=300x200
    wait_log b "round 0 configured"
    sleep 0.4
    dump                                                                      # 1
    expect 1 "view 11 0,0 1280x720 focused=true"
    expect 1 "state 11 floating=false fullscreen=true maximized=false visible=true managed=true ws=2 output=1"
    expect 1 "state 12 floating=false fullscreen=false maximized=false visible=true managed=true ws=2 output=1"
    stop
}

r6() {
    name="a rule with a bad pattern is reported and ignored"
    RULES=$rules start "$cfg" 0
    grep -q "window-rules: rule 7 ignored" "$tmp/raywm.log" || fail "the bad rule was not reported"
    if grep -q "window-rules: rule [1-6] ignored" "$tmp/raywm.log"; then fail "a valid rule was rejected"; fi
    launch a $plain RAYWM_TEST_APP_ID=x
    wait_log a "frame done"
    sleep 0.2
    dump                                                                      # 1
    expect 1 "state 11 floating=false fullscreen=false maximized=false visible=true managed=true ws=2 output=1"
    stop
}

run_scenarios rules r1 r2 r3 r4 r5 r6

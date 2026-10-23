#!/bin/sh
# Workspaces with REAL input events (virtual pointer and keyboard in an
# isolated headless compositor): switching, moving windows, focus, hidden
# windows getting no input, floating and fullscreen windows, outputs
# unplugged and plugged in, reload, and a config without workspaces.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/workspaces.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "workspaces: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
. "$root/tests/support/harness.sh"

cfg="$root/tests/workspaces/init.lua"
helpers="$root/tests/workspaces/plugins"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
super_key() { drive key super down key "$1" down key "$1" up key super up sleep 300; }
super_shift() { drive key super down key shift down key "$1" down key "$1" up key shift up key super up sleep 300; }
super_ctrl() { drive key super down key ctrl down key "$1" down key "$1" up key ctrl up key super up sleep 300; }
# One output: its id is 1, its workspaces 2..10 ("1".."9"); windows from 11.

ws1() {
    name="Super+N switches workspaces; windows of hidden ones get no input"
    WIN=$plain PLUGINS=$helpers start "$cfg" 1
    dump                                                                      # 1
    expect 1 "where 11 1@HEADLESS-1"
    expect 1 "ws 1@HEADLESS-1 output=HEADLESS-1 active=true orphan=false"
    expect 1 "ws 9@HEADLESS-1 output=HEADLESS-1 active=false orphan=false"
    super_key 2
    dump                                                                      # 2
    expect 2 "ws 1@HEADLESS-1 output=HEADLESS-1 active=false orphan=false"
    expect 2 "ws 2@HEADLESS-1 output=HEADLESS-1 active=true orphan=false"
    expect 2 "view 11 8,8 1264x704 focused=false"
    expect 2 "state 11 floating=false fullscreen=false maximized=false visible=false managed=true ws=2 output=1"
    has a "deactivated"
    launch b $plain
    wait_log b "frame done"
    sleep 0.3
    dump                                                                      # 3
    expect 3 "view 12 8,8 1264x704 focused=true"
    expect 3 "where 12 2@HEADLESS-1"
    # Where a would be, the click goes to b: a is hidden.
    drive move 300 300 down left up left sleep 150
    lacks a "ptr button 272 pressed"
    has b "ptr button 272 pressed window"
    super_key 1
    dump                                                                      # 4
    expect 4 "view 11 8,8 1264x704 focused=true"
    expect 4 "state 12 floating=false fullscreen=false maximized=false visible=false managed=true ws=3 output=1"
    stop
}

ws2() {
    name="Super+Shift+N moves the focused window; focus stays on the workspace"
    WIN=$plain PLUGINS=$helpers start "$cfg" 2
    super_shift 2                                            # b (12) to "2"
    dump                                                                      # 1
    expect 1 "view 11 8,8 1264x704 focused=true"
    expect 1 "where 12 2@HEADLESS-1"
    expect 1 "state 12 floating=false fullscreen=false maximized=false visible=false managed=true ws=3 output=1"
    super_key 2
    dump                                                                      # 2
    expect 2 "view 12 8,8 1264x704 focused=true"
    expect 2 "state 11 floating=false fullscreen=false maximized=false visible=false managed=true ws=2 output=1"
    stop
}

ws3() {
    name="closing the last window of a workspace does not focus a hidden one"
    WIN="$plain RAYWM_TEST_CLOSE=1" PLUGINS=$helpers start "$cfg" 1
    super_key 2
    launch b $plain RAYWM_TEST_CLOSE=1
    wait_log b "frame done"
    sleep 0.3
    super_key q                                              # b closes
    wait_log b "closing"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "view 11 8,8 1264x704 focused=false"
    [ "$(grep -c 'client: activated' "$tmp/a.log")" -eq 1 ] || fail "a was focused again while hidden"
    super_key 1
    dump                                                                      # 2
    expect 2 "view 11 8,8 1264x704 focused=true"
    stop
}

ws4() {
    name="a window opening on a hidden workspace is never shown nor focused"
    WIN=$plain PLUGINS=$helpers start "$cfg" 1
    launch b $plain RAYWM_TEST_APP_ID=raywm-test-ws2
    wait_log b "round 0 configured"
    sleep 0.4
    dump                                                                      # 1
    expect 1 "view 11 8,8 1264x704 focused=true"
    expect 1 "where 12 2@HEADLESS-1"
    expect 1 "state 12 floating=false fullscreen=false maximized=false visible=false managed=true ws=3 output=1"
    lacks b "surface enter"
    lacks b "client: activated"
    lacks a "deactivated"
    super_key 2
    wait_log b "surface enter"
    dump                                                                      # 2
    expect 2 "view 12 8,8 1264x704 focused=true"
    stop
}

ws5() {
    name="floating and fullscreen windows go with their workspace"
    WIN=$plain PLUGINS=$helpers start "$cfg" 2
    drive key super down key shift down key space down key space up key shift up key super up sleep 300   # b floats
    super_key 2
    launch c $plain
    wait_log c "frame done"
    sleep 0.3
    super_key f                                              # c fullscreen on "2"
    super_key 1
    dump                                                                      # 1
    # c's fullscreen is hidden with "2": it does not hold the keyboard.
    expect 1 "state 13 floating=false fullscreen=true maximized=false visible=false managed=true ws=3 output=1"
    expect 1 "view 12 540,285 200x150 focused=true"
    expect 1 "state 12 floating=true fullscreen=false maximized=false visible=true managed=false ws=2 output=1"
    super_key 2
    dump                                                                      # 2
    expect 2 "view 13 0,0 1280x720 focused=true"
    expect 2 "state 12 floating=true fullscreen=false maximized=false visible=false managed=false ws=2 output=1"
    stop
}

ws6() {
    name="an unplugged output's workspaces move with their windows"
    OUTPUTS=2 WIN=$plain PLUGINS=$helpers start "$cfg" 0
    drive move 1900 360                                      # the right output: HEADLESS-1
    launch a $plain
    wait_log a "frame done"
    sleep 0.3
    super_key 3
    launch b $plain
    wait_log b "frame done"
    sleep 0.3
    unplug HEADLESS-1
    sleep 0.4
    dump                                                                      # 1
    expect 1 "ws 1@HEADLESS-1 output=HEADLESS-2 active=false orphan=false"
    expect 1 "ws 3@HEADLESS-1 output=HEADLESS-2 active=false orphan=false"
    expect 1 "ws 1@HEADLESS-2 output=HEADLESS-2 active=true orphan=false"
    awk '/^dump 1$/ {on=1; next} on && /^view / {split($3, p, ","); if (p[1] + 0 >= 1280) bad=1} END {exit bad}' "$tmp/probe.log" ||
        fail "a window stayed outside the remaining output"
    # Super+1 there shows the output's own "1", not the one that moved in.
    super_key 1
    dump                                                                      # 2
    expect 2 "ws 1@HEADLESS-2 output=HEADLESS-2 active=true orphan=false"
    stop
}

ws7() {
    name="a new output gets its nine workspaces"
    WIN=$plain PLUGINS=$helpers start "$cfg" 0
    plug
    sleep 0.5
    dump                                                                      # 1
    expect 1 "ws 1@HEADLESS-2 output=HEADLESS-2 active=true orphan=false"
    expect 1 "ws 9@HEADLESS-2 output=HEADLESS-2 active=false orphan=false"
    expect 1 "ws 1@HEADLESS-1 output=HEADLESS-1 active=true orphan=false"
    [ "$(awk '/^dump 1$/ {on=1; next} /^dump / {on=0} on && /^ws /' "$tmp/probe.log" | wc -l)" -eq 18 ] ||
        fail "expected 18 workspaces"
    stop
}

ws8() {
    name="reload keeps the workspaces and which window is where"
    WIN=$plain PLUGINS=$helpers start "$cfg" 2
    super_shift 2
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 400
    dump                                                                      # 1
    expect 1 "where 11 1@HEADLESS-1"
    expect 1 "where 12 2@HEADLESS-1"
    expect 1 "ws 2@HEADLESS-1 output=HEADLESS-1 active=false orphan=false"
    expect 1 "view 11 8,8 1264x704 focused=true"
    [ "$(awk '/^dump 1$/ {on=1; next} /^dump / {on=0} on && /^ws /' "$tmp/probe.log" | wc -l)" -eq 9 ] ||
        fail "reload duplicated or lost workspaces"
    lacks raywm "has no plugin any more"
    super_key 2
    dump                                                                      # 2
    expect 2 "view 12 8,8 1264x704 focused=true"
    stop
}

ws9() {
    name="removing the workspace plugin from the config shows every window"
    WIN=$plain PLUGINS=$helpers start "$cfg" 2
    super_shift 2                                            # b hidden on "2"
    cp "$root/tests/workspaces/noworkspaces.lua" "$tmp/config/raywm/init.lua"
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 500
    dump                                                                      # 1
    [ "$(awk '/^dump 1$/ {on=1; next} /^dump / {on=0} on && /^ws /' "$tmp/probe.log" | wc -l)" -eq 0 ] ||
        fail "orphaned workspaces were kept"
    expect 1 "state 12 floating=false fullscreen=false maximized=false visible=true managed=true ws=0 output=1"
    expect 1 "view 11 8,8 628x704 focused=true"
    expect 1 "view 12 644,8 628x704 focused=false"
    grep -q "has no plugin any more" "$tmp/raywm.log" || fail "no log line about the released workspaces"
    stop
}

ws10() {
    name="a plugin cannot give the keyboard to a hidden window"
    WIN=$plain PLUGINS=$helpers start "$cfg" 2
    super_shift 2                                            # b hidden
    drive key super down key f9 down key f9 up key super up sleep 300
    dump                                                                      # 1
    expect 1 "view 11 8,8 1264x704 focused=true"
    expect 1 "view 12 644,8 628x704 focused=false"
    [ "$(grep -c 'client: activated' "$tmp/b.log")" -eq 1 ] || fail "hidden b was activated"
    stop
}

ws11() {
    name="Super+Alt+Right moves a window to the next output"
    OUTPUTS=2 WIN=$plain PLUGINS=$helpers start "$cfg" 0
    drive move 300 360                                       # the left output: HEADLESS-2
    launch a $plain
    wait_log a "frame done"
    sleep 0.3
    drive key super down key alt down key right down key right up key alt up key super up sleep 400
    dump                                                                      # 1
    expect 1 "where 21 1@HEADLESS-1"
    awk '/^dump 1$/ {on=1; next} on && /^view 21 / {split($3, p, ","); if (p[1] + 0 >= 1280) ok=1} END {exit !ok}' "$tmp/probe.log" ||
        fail "a is not on the right output"
    awk '/^dump 1$/ {on=1; next} on && /^view 21 / {if ($5 == "focused=true") ok=1} END {exit !ok}' "$tmp/probe.log" ||
        fail "a lost the keyboard"
    stop
}

ws12() {
    name="showing a workspace whose last focused window is behind a fullscreen one"
    WIN=$plain PLUGINS=$helpers start "$cfg" 1
    super_key 2
    launch w $plain
    wait_log w "frame done"
    launch f $plain RAYWM_TEST_APP_ID=raywm-test-fs
    wait_log f "frame done"
    sleep 0.3
    super_key h                                              # w (left) focused last on "2"
    super_key 1
    # f goes fullscreen while "2" is hidden; w is now behind it.
    drive key super down key f10 down key f10 up key super up sleep 300
    super_key 2
    dump                                                                      # 1
    expect 1 "view 13 0,0 1280x720 focused=true"
    expect 1 "view 12 8,8 628x704 focused=false"
    expect 1 "view 11 8,8 1264x704 focused=false"
    stop
}

run_scenarios workspaces ws1 ws2 ws3 ws4 ws5 ws6 ws7 ws8 ws9 ws10 ws11 ws12

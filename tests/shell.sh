#!/bin/sh
# Window states and requests (xdg-shell v7, xdg-decoration, minimize,
# xdg-activation) with REAL input events in an isolated headless
# compositor: what clients are told (capabilities, bounds, tiled,
# constrained and suspended states, decoration modes), minimizing and
# restoring, and activation with and without user input.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/shell.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "shell: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
. "$root/tests/support/harness.sh"

cfg="$root/tests/shell/init.lua"
switch_cfg="$root/tests/shell/switch.lua"
helpers="$root/tests/shell/plugins"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
v7="$plain RAYWM_TEST_XDG_VERSION=7"
super_key() { drive key super down key "$1" down key "$1" up key super up sleep 300; }
super_shift() { drive key super down key shift down key "$1" down key "$1" up key shift up key super up sleep 300; }
client_key() { drive sleep 300 key "$1" down key "$1" up sleep 300; }
# count <name> <fixed line>: how often <name>.log has the client line.
count() { grep -cxF "client: $2" "$tmp/$1.log" || true; }
# expect_not <dump-number> <line>: dump N does not contain this line.
expect_not() {
    if awk -v n="dump $1" '$0 == n {on=1; next} /^dump / {on=0} on' "$tmp/probe.log" | grep -qxF "$2"; then
        fail "dump $1: unexpected '$2'"
    fi
}
# One output: its id is 1, its workspaces 2..10 ("1".."9"); windows from 11.

s1() {
    name="xdg-shell v7: capabilities, bounds, tiled and constrained states"
    WIN=$v7 PLUGINS=$helpers start "$cfg" 1
    has a "capabilities maximize fullscreen minimize"
    has a "bounds 1280x720"
    # Tiled by dwindle: told so, with all edges constrained.
    has a "tiled on"
    has a "constrained on"
    super_shift space                                        # a floats
    wait_log a "tiled off"
    has a "constrained off"
    super_shift space                                        # tiled again
    [ "$(count a "tiled on")" -eq 2 ] || fail "a: tiled again expected"
    # A client of an older version (2) gets only the tiled states.
    launch b $plain
    wait_log b "frame done"
    sleep 0.3
    has b "tiled on"
    lacks b "capabilities"
    lacks b "bounds"
    lacks b "constrained"
    stop
}

s2() {
    name="suspended: windows on a hidden workspace may stop drawing"
    WIN=$v7 PLUGINS=$helpers start "$cfg" 1
    lacks a "suspended"
    super_key 2
    wait_log a "suspended on"
    super_key 1
    wait_log a "suspended off"
    dump                                                                      # 1
    expect 1 "view 11 8,8 1264x704 focused=true"
    stop
}

s3() {
    name="decorations: the client's choice, no preference, plugin override, window rule"
    RULES="$root/tests/shell/rules.lua" PLUGINS=$helpers start "$cfg" 0
    launch a $plain RAYWM_TEST_DECORATION=client
    wait_log a "frame done"
    launch b $plain RAYWM_TEST_DECORATION=server
    wait_log b "frame done"
    launch c $plain RAYWM_TEST_DECORATION=unset
    wait_log c "frame done"
    launch d $plain RAYWM_TEST_DECORATION=server RAYWM_TEST_APP_ID=raywm-test-csd
    wait_log d "frame done"
    sleep 0.3
    has a "decoration client_side"
    has b "decoration server_side"
    has c "decoration server_side"                           # no preference
    wait_log d "decoration client_side"                      # the rule
    dump                                                                      # 1
    expect 1 "shell 11 minimized=false urgent=false decoration=client"
    expect 1 "shell 12 minimized=false urgent=false decoration=server"
    expect 1 "shell 14 minimized=false urgent=false decoration=client"
    super_key f9                                             # every window "server"
    wait_log a "decoration server_side"
    dump                                                                      # 2
    expect 2 "shell 11 minimized=false urgent=false decoration=server"
    expect 2 "shell 14 minimized=false urgent=false decoration=server"
    super_key f10                                            # back to "auto"
    sleep 0.2
    [ "$(count a "decoration client_side")" -eq 2 ] || fail "a: client-side again expected"
    [ "$(count c "decoration server_side")" -eq 1 ] || fail "c: no change expected"
    stop
}

s4() {
    name="minimize: client request, Super+n; Super+Shift+n restores; tiling follows"
    WIN="$v7 RAYWM_TEST_REQUEST_KEYS=1" PLUGINS=$helpers start "$cfg" 2
    client_key f8                                            # b asks
    wait_log b "minimize requested"
    sleep 0.2
    dump                                                                      # 1
    expect 1 "shell 12 minimized=true urgent=false decoration=nil"
    expect 1 "state 12 floating=false fullscreen=false maximized=false visible=false managed=false ws=2 output=1"
    expect 1 "view 11 8,8 1264x704 focused=true"
    has b "suspended on"
    super_key n                                              # a too
    dump                                                                      # 2
    expect 2 "shell 11 minimized=true urgent=false decoration=nil"
    expect 2 "view 11 8,8 1264x704 focused=false"
    super_shift n                                            # the last one: a
    dump                                                                      # 3
    expect 3 "shell 11 minimized=false urgent=false decoration=nil"
    expect 3 "view 11 8,8 1264x704 focused=true"
    super_shift n                                            # then b
    dump                                                                      # 4
    expect 4 "view 11 8,8 628x704 focused=false"
    expect 4 "view 12 644,8 628x704 focused=true"
    has b "suspended off"
    # Nothing left to restore: harmless.
    super_shift n
    stop
}

s5() {
    name="activation from user input in another window focuses a visible one"
    PLUGINS=$helpers start "$cfg" 0
    launch a $plain RAYWM_TEST_ACTIVATE_FROM="$tmp/token"
    wait_log a "frame done"
    launch b $plain RAYWM_TEST_TOKEN_TO="$tmp/token"
    wait_log b "frame done"
    sleep 0.3
    client_key f7                                            # b: a link is clicked
    wait_log b "token written"
    has b "token requested (input)"
    wait_log a "activate sent"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "view 11 8,8 628x704 focused=true"
    expect 1 "shell 11 minimized=false urgent=false decoration=nil"
    [ "$(count a activated)" -eq 2 ] || fail "a: activated again expected"
    stop
}

s6() {
    name="activation without user input only marks the window urgent"
    PLUGINS=$helpers start "$cfg" 0
    launch a $plain RAYWM_TEST_ACTIVATE_SELF="$tmp/go"
    wait_log a "frame done"
    launch b $plain
    wait_log b "frame done"
    sleep 0.3
    touch "$tmp/go"
    wait_log a "activate sent"
    has a "token requested"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "view 12 644,8 628x704 focused=true"
    expect 1 "shell 11 minimized=false urgent=true decoration=nil"
    expect 1 "urgent-ws 1@HEADLESS-1"
    # Focused by the user: no longer urgent.
    drive move 300 300 down left up left sleep 200
    dump                                                                      # 2
    expect 2 "view 11 8,8 628x704 focused=true"
    expect 2 "shell 11 minimized=false urgent=false decoration=nil"
    expect_not 2 "urgent-ws 1@HEADLESS-1"
    stop
}

s7() {
    name="user activation on a hidden workspace: urgent there; Super+1 shows and focuses it"
    PLUGINS=$helpers start "$cfg" 0
    launch a $plain RAYWM_TEST_ACTIVATE_FROM="$tmp/token"
    wait_log a "frame done"
    sleep 0.2
    super_key 2
    launch b $plain RAYWM_TEST_TOKEN_TO="$tmp/token"
    wait_log b "frame done"
    sleep 0.3
    client_key f7
    wait_log a "activate sent"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "ws 2@HEADLESS-1 output=HEADLESS-1 active=true orphan=false"
    expect 1 "view 12 8,8 1264x704 focused=true"
    expect 1 "shell 11 minimized=false urgent=true decoration=nil"
    expect 1 "urgent-ws 1@HEADLESS-1"
    super_key 1
    dump                                                                      # 2
    expect 2 "view 11 8,8 1264x704 focused=true"
    expect 2 "shell 11 minimized=false urgent=false decoration=nil"
    expect_not 2 "urgent-ws 1@HEADLESS-1"
    stop
}

s8() {
    name="activation = \"switch\": a user request shows the workspace and focuses the window"
    PLUGINS=$helpers start "$switch_cfg" 0
    launch a $plain RAYWM_TEST_ACTIVATE_FROM="$tmp/token"
    wait_log a "frame done"
    sleep 0.2
    super_key 2
    launch b $plain RAYWM_TEST_TOKEN_TO="$tmp/token"
    wait_log b "frame done"
    sleep 0.3
    client_key f7
    wait_log a "activate sent"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "ws 1@HEADLESS-1 output=HEADLESS-1 active=true orphan=false"
    expect 1 "view 11 8,8 1264x704 focused=true"
    expect 1 "shell 11 minimized=false urgent=false decoration=nil"
    stop
}

s9() {
    name="layer-shell v5: an exclusive zone on the edge the panel chose"
    PLUGINS=$helpers start "$cfg" 0
    # A v4 panel (top, exclusive zone 30) still works with v5.
    launch top RAYWM_TEST_LAYER=1
    wait_log top "layer frame done"
    # A corner panel with its zone on the left edge (set_exclusive_edge).
    launch left RAYWM_TEST_LAYER=1 RAYWM_TEST_LAYER_EDGE=1
    wait_log left "layer frame done"
    launch a $plain
    wait_log a "frame done"
    sleep 0.3
    has left "layer configured 30x200"
    dump                                                                      # 1
    expect 1 "view 11 38,38 1234x674 focused=true"
    expect 1 "output HEADLESS-1 0,0 1280x720 scale=1.0 transform=normal enabled=true power=true mode=1280x720 usable=30,30 1250x690"
    stop
}

run_scenarios shell s1 s2 s3 s4 s5 s6 s7 s8 s9

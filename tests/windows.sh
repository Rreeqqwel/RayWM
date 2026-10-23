#!/bin/sh
# Window management with REAL input events (virtual pointer and keyboard in
# an isolated headless compositor): when new windows are shown, floating
# and tiled windows, dwindle's resize/swap/split keys, reload.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/windows.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "windows: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
. "$root/tests/support/harness.sh"

tiled="$root/tests/windows/tiled.lua"
# Windows that log pointer and keyboard events but never start a
# client-side move on their own.
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"

# <name> is shown (wl_surface.enter) only after it drew the size <WxH>.
shown_after_resize() {
    awk -v r="client: hold resized $2" '$0 == r && !rs {rs = NR} /client: surface enter/ && !en {en = NR} END {exit !(rs && en && rs < en)}' "$tmp/$1.log" ||
        fail "$1 was shown before it had its size $2"
}
toggle_float() { drive key super down key shift down key space down key space up key shift up key super up sleep 300; }

w1() {
    name="a tiled window is shown only once it has its tile size"
    WIN=$plain start "$tiled" 1
    shown_after_resize a 1264x704
    dump                                                                      # 1
    expect 1 "view 2 8,8 1264x704 focused=true"
    expect 1 "state 2 floating=false fullscreen=false maximized=false visible=true managed=true ws=0 output=1"
    # The second window splits the first; it too appears only at its size.
    launch b $plain
    wait_log b "surface enter"
    shown_after_resize b 628x704
    dump                                                                      # 2
    expect 2 "view 2 8,8 628x704 focused=false"
    expect 2 "view 3 644,8 628x704 focused=true"
    stop
}

w2() {
    name="a floating window is shown at once, at its own size"
    WIN=$plain start "$root/tests/input/floating.lua" 1
    wait_log a "surface enter"
    lacks a "hold resized"
    dump                                                                      # 1
    expect 1 "view 2 540,285 200x150 focused=true"
    expect 1 "state 2 floating=false fullscreen=false maximized=false visible=true managed=false ws=0 output=1"
    stop
}

w3() {
    name="Super+Shift+Space floats a tiled window and tiles it again"
    WIN=$plain start "$tiled" 2
    toggle_float
    dump                                                                      # 1
    # b floats centred at the size it chose (200x150); a takes the space.
    expect 1 "view 3 540,285 200x150 focused=true"
    expect 1 "state 3 floating=true fullscreen=false maximized=false visible=true managed=false ws=0 output=1"
    expect 1 "view 2 8,8 1264x704 focused=false"
    # Moved while floating (Super+drag works: it is not managed) ...
    drive move 640 360 key super down down left move 700 375 up left key super up sleep 200
    dump                                                                      # 2
    expect 2 "view 3 600,300 200x150 focused=true"
    # ... tiled again: back into the tree ...
    toggle_float
    dump                                                                      # 3
    expect 3 "view 2 8,8 628x704 focused=false"
    expect 3 "view 3 644,8 628x704 focused=true"
    expect 3 "state 3 floating=false fullscreen=false maximized=false visible=true managed=true ws=0 output=1"
    # ... and floating once more: where it last floated.
    toggle_float
    dump                                                                      # 4
    expect 4 "view 3 600,300 200x150 focused=true"
    expect 4 "view 2 8,8 1264x704 focused=false"
    stop
}

w4() {
    name="floating windows stay above tiled ones"
    WIN=$plain start "$tiled" 2
    toggle_float                        # b floats at 540,285 over a
    drive move 100 100 down left up left sleep 150   # focus a (tiled, below)
    dump                                                                      # 1
    expect 1 "view 2 8,8 1264x704 focused=true"
    # A click where both are: the floating window is on top and gets it.
    drive move 600 350 down left up left sleep 150
    dump                                                                      # 2
    expect 2 "view 3 540,285 200x150 focused=true"
    [ "$(grep -c 'client: ptr button 272 pressed window' "$tmp/b.log")" -ge 1 ] || fail "b (floating, on top) got no press"
    stop
}

w5() {
    name="dwindle keys: resize, swap and split direction"
    WIN=$plain start "$tiled" 2
    # b (focused, right) has no neighbour to its right: its left edge moves.
    drive key super down key ctrl down key l down key l up key ctrl up key super up sleep 300
    dump                                                                      # 1
    expect 1 "view 2 8,8 668x704 focused=false"
    expect 1 "view 3 684,8 588x704 focused=true"
    # Swap with the window to the left.
    drive key super down key shift down key h down key h up key shift up key super up sleep 300
    dump                                                                      # 2
    expect 2 "view 3 8,8 668x704 focused=true"
    expect 2 "view 2 684,8 588x704 focused=false"
    # Side by side -> stacked (the ratio stays).
    drive key super down key t down key t up key super up sleep 300
    dump                                                                      # 3
    expect 3 "view 3 8,8 1264x370 focused=true"
    expect 3 "view 2 8,386 1264x326 focused=false"
    # None of these keys reached a client.
    lacks a "kbd key 38 pressed"
    lacks b "kbd key 38 pressed"
    lacks b "kbd key 20 pressed"
    stop
}

w6() {
    name="reload keeps floating windows floating and the tiles in place"
    WIN=$plain start "$tiled" 3
    toggle_float                        # c floats
    dump                                                                      # 1
    expect 1 "view 4 540,285 200x150 focused=true"
    expect 1 "view 2 8,8 628x704 focused=false"
    expect 1 "view 3 644,8 628x704 focused=false"
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 400
    dump                                                                      # 2
    expect 2 "view 4 540,285 200x150 focused=true"
    expect 2 "state 4 floating=true fullscreen=false maximized=false visible=true managed=false ws=0 output=1"
    expect 2 "view 2 8,8 628x704 focused=false"
    expect 2 "view 3 644,8 628x704 focused=false"
    stop
}

w7() {
    name="floating windows on two outputs"
    OUTPUTS=2 WIN=$plain start "$tiled" 2
    # a and b tile output 1; float b, drag it onto output 2.
    toggle_float
    drive move 640 360 key super down down left move 1900 360 up left key super up sleep 200
    dump                                                                      # 1
    # (Two outputs: ids 1 and 2; the windows are 3 and 4.)
    expect 1 "view 4 1800,285 200x150 focused=true"
    expect 1 "state 4 floating=true fullscreen=false maximized=false visible=true managed=false ws=0 output=2"
    expect 1 "view 3 8,8 1264x704 focused=false"
    # Tiled again: it joins the tiling of the output it is on.
    toggle_float
    dump                                                                      # 2
    expect 2 "view 4 1288,8 1264x704 focused=true"
    expect 2 "view 3 8,8 1264x704 focused=false"
    stop
}

run_scenarios windows w1 w2 w3 w4 w5 w6 w7

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

# ---- fullscreen and maximize ------------------------------------------------
float_cfg="$root/tests/windows/floating.lua"
super_key() { drive key super down key "$1" down key "$1" up key super up sleep 300; }
# A plain key for the client: each driver run has a new virtual keyboard,
# and the client needs a moment to get its wl_keyboard back.
client_key() { drive sleep 300 key "$1" down key "$1" up sleep 300; }

w8() {
    name="Super+F: fullscreen covers the panel, then back to the tile"
    WIN=$plain start "$tiled" 1 panel-ptr
    dump                                                                      # 1
    expect 1 "view 2 8,38 1264x674 focused=true"
    super_key f
    dump                                                                      # 2
    expect 2 "view 2 0,0 1280x720 focused=true"
    expect 2 "state 2 floating=false fullscreen=true maximized=false visible=true managed=true ws=0 output=1"
    has a "fullscreen on 1280x720"
    # The panel is below it now: a click there goes to the window.
    drive move 100 10 down left up left sleep 150
    lacks panel "ptr button 272 pressed"
    [ "$(grep -c 'client: ptr button 272 pressed window' "$tmp/a.log")" -ge 1 ] || fail "a got no press over the panel"
    super_key f
    dump                                                                      # 3
    expect 3 "view 2 8,38 1264x674 focused=true"
    expect 3 "state 2 floating=false fullscreen=false maximized=false visible=true managed=true ws=0 output=1"
    has a "fullscreen off 1264x674"
    stop
}

w9() {
    name="a fullscreen window keeps the keyboard; new windows open behind it"
    WIN=$plain start "$tiled" 1
    super_key f
    launch b $plain
    wait_log b "frame done"
    sleep 0.3
    dump                                                                      # 1
    expect 1 "view 2 0,0 1280x720 focused=true"
    expect 1 "state 3 floating=false fullscreen=false maximized=false visible=true managed=true ws=0 output=1"
    lacks b "client: activated"
    # Focus keys cannot move the keyboard to a window behind it.
    super_key l
    dump                                                                      # 2
    expect 2 "view 2 0,0 1280x720 focused=true"
    # After fullscreen ends, b is a normal tile again and can be focused.
    super_key f
    super_key l
    dump                                                                      # 3
    expect 3 "view 2 8,8 628x704 focused=false"
    expect 3 "view 3 644,8 628x704 focused=true"
    stop
}

w10() {
    name="client requests: fullscreen before mapping, F9 and F10 toggles"
    WIN="$plain RAYWM_TEST_FULLSCREEN=1 RAYWM_TEST_REQUEST_KEYS=1" start "$tiled" 1
    has a "round 0 configured 1280x720"
    has a "fullscreen on 1280x720"
    dump                                                                      # 1
    expect 1 "view 2 0,0 1280x720 focused=true"
    expect 1 "state 2 floating=false fullscreen=true maximized=false visible=true managed=true ws=0 output=1"
    # Dwindle's tile was only remembered: the tile size was never sent.
    lacks a "hold resized 1264x704"
    client_key f9                                            # leave fullscreen
    dump                                                                      # 2
    expect 2 "view 2 8,8 1264x704 focused=true"
    has a "fullscreen off 1264x704"
    client_key f10                                           # maximize
    dump                                                                      # 3
    expect 3 "view 2 0,0 1280x720 focused=true"
    expect 3 "state 2 floating=false fullscreen=false maximized=true visible=true managed=true ws=0 output=1"
    has a "maximized on 1280x720"
    client_key f10
    dump                                                                      # 4
    expect 4 "view 2 8,8 1264x704 focused=true"
    has a "maximized off 1264x704"
    stop
}

w11() {
    name="a plugin can refuse a fullscreen request; the client still gets an answer"
    WIN="$plain RAYWM_TEST_REQUEST_KEYS=1" PLUGINS="$root/tests/windows/plugins" start "$root/tests/windows/deny.lua" 1
    client_key f9
    has a "fullscreen requested on"
    lacks a "fullscreen on"
    dump                                                                      # 1
    expect 1 "view 2 8,8 1264x704 focused=true"
    expect 1 "state 2 floating=false fullscreen=false maximized=false visible=true managed=true ws=0 output=1"
    stop
}

w12() {
    name="the dialog of a fullscreen window is shown above it and can be focused"
    WIN="$plain RAYWM_TEST_CHILD=1" start "$float_cfg" 1
    wait_log a "child mapped"
    sleep 0.2
    # The window is 540,285 200x150, its dialog 580,315 120x90 on top.
    drive move 550 290 down left up left sleep 150           # focus the window
    super_key f
    dump                                                                      # 1
    expect 1 "view 2 0,0 1280x720 focused=true"
    # The dialog (120x90, centred) is above the fullscreen window.
    drive move 640 360 down left up left sleep 150
    dump                                                                      # 2
    expect 2 "view 3 580,315 120x90 focused=true"
    expect 2 "state 2 floating=false fullscreen=true maximized=false visible=true managed=false ws=0 output=1"
    # Focusing the fullscreen window again raises it, but not over its dialog.
    drive move 100 100 down left up left sleep 150
    drive move 640 360 down left up left sleep 150
    dump                                                                      # 3
    expect 3 "view 3 580,315 120x90 focused=true"
    stop
}

# (Headless outputs: HEADLESS-2 is the left one, id 1; HEADLESS-1 the
# right one, id 2.)
fullscreen_on_right() {
    OUTPUTS=2 WIN=$plain start "$tiled" 0
    drive move 1900 360
    launch b $plain
    wait_log b "frame done"
    sleep 0.3
    super_key f
    dump                                                                      # 1
    expect 1 "view 3 1280,0 1280x720 focused=true"
    expect 1 "state 3 floating=false fullscreen=true maximized=false visible=true managed=true ws=0 output=2"
}

w13() {
    name="a fullscreen window on an unplugged output moves to the other one"
    fullscreen_on_right
    unplug HEADLESS-1
    sleep 0.4
    dump                                                                      # 2
    expect 2 "view 3 0,0 1280x720 focused=true"
    expect 2 "state 3 floating=false fullscreen=true maximized=false visible=true managed=true ws=0 output=1"
    stop
}

w15() {
    name="a fullscreen window follows its output when the other one goes away"
    fullscreen_on_right
    unplug HEADLESS-2                     # the left output: the right one moves to x=0
    sleep 0.4
    dump                                                                      # 2
    expect 2 "view 3 0,0 1280x720 focused=true"
    expect 2 "state 3 floating=false fullscreen=true maximized=false visible=true managed=true ws=0 output=2"
    stop
}

w14() {
    name="a maximized window follows the usable area; Super+drag leaves it alone"
    WIN=$plain start "$float_cfg" 1
    super_key m
    dump                                                                      # 1
    expect 1 "view 2 0,0 1280x720 focused=true"
    expect 1 "state 2 floating=false fullscreen=false maximized=true visible=true managed=false ws=0 output=1"
    launch p RAYWM_TEST_LAYER=1
    wait_log p "layer frame done"
    sleep 0.3
    dump                                                                      # 2
    expect 2 "view 2 0,30 1280x690 focused=true"
    drive move 640 360 key super down down left move 700 400 up left key super up sleep 200
    dump                                                                      # 3
    expect 3 "view 2 0,30 1280x690 focused=true"
    super_key m
    dump                                                                      # 4
    expect 4 "view 2 540,285 200x150 focused=true"
    expect 4 "state 2 floating=false fullscreen=false maximized=false visible=true managed=false ws=0 output=1"
    stop
}

run_scenarios windows w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15

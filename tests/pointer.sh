#!/bin/sh
# Implicit pointer grab tests: REAL pointer events (virtual pointer) and
# REAL clients that log every wl_pointer event they receive (enter, leave,
# motion with surface-local coordinates, button), inside an isolated
# headless compositor. See docs/ARCHITECTURE.md, "Pointer input and grabs".
#
# Windows float at fixed positions (tests/pointer/plugins/spread.lua):
#   A 100..300 x 100..250, B 500..700, C 900..1100 (same y), each 200x150.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=text] tests/pointer.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "pointer: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
. "$root/tests/support/harness.sh"
PLUGINS="$root/tests/pointer/plugins"
cfg="$root/tests/pointer/init.lua"
ptr_win="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"

# stream <name> <after-line> <expected lines...>: the pointer events of a
# client after <after-line> are exactly the expected lines, in order.
stream() {
    n=$1; after=$2; shift 2
    want=$(for l in "$@"; do echo "client: $l"; done)
    got=$(ptr_after "$n" "$after")
    [ "$got" = "$want" ] || fail "$n after '$after': got [$(echo "$got" | sed 's/^client: //' | tr '\n' '|')] want [$(echo "$want" | sed 's/^client: //' | tr '\n' '|')]"
}
# last_ptr <name> <expected lines...>: the client's last pointer events.
last_ptr() {
    n=$1; shift
    want=$(for l in "$@"; do echo "client: $l"; done)
    got=$(grep "client: ptr " "$tmp/$n.log" | tail -n $#)
    [ "$got" = "$want" ] || fail "$n ends with [$(echo "$got" | sed 's/^client: //' | tr '\n' '|')] want [$(echo "$want" | sed 's/^client: //' | tr '\n' '|')]"
}
# all_ptr <name> <expected lines...>: every pointer event the client got.
all_ptr() {
    n=$1; shift
    want=$(for l in "$@"; do echo "client: $l"; done)
    got=$(grep "client: ptr " "$tmp/$n.log" || true)
    [ "$got" = "$want" ] || fail "$n: got [$(echo "$got" | sed 's/^client: //' | tr '\n' '|')] want [$(echo "$want" | sed 's/^client: //' | tr '\n' '|')]"
}

# ---- the basic implicit grab ----------------------------------------------
p1() {
    name="press in A, drag across B, release over B"
    WIN=$ptr_win start "$cfg" 2
    drive move 150 150 down left move 400 160 move 600 170 move 650 180 up left sleep 200 move 610 170 sleep 150
    stream a "ptr button 272 pressed window" \
        "ptr motion 300,60" "ptr motion 500,70" "ptr motion 550,80" \
        "ptr button 272 released window" "ptr leave window"
    # B saw nothing while A held the button; after the release the pointer
    # is re-evaluated and B gets it.
    all_ptr b "ptr enter window at 150,80" "ptr motion 110,70"
    # No focus change by dragging: A (clicked) has the keyboard.
    dump                                                                      # 1
    expect 1 "view 2 100,100 200x150 focused=true"
    expect 1 "view 3 500,100 200x150 focused=false"
    # A later ordinary click on B works.
    drive move 600 150 down left up left sleep 150
    stream b "ptr motion 110,70" "ptr motion 100,50" "ptr button 272 pressed window" "ptr button 272 released window"
    stop
}

p2() {
    name="several buttons: the grab ends with the last release"
    WIN=$ptr_win start "$cfg" 2
    drive move 150 150 down left move 400 160 down right up left move 600 170 sleep 100 up right sleep 200 move 610 175 sleep 150
    stream a "ptr button 272 pressed window" \
        "ptr motion 300,60" "ptr button 273 pressed window" \
        "ptr button 272 released window" "ptr motion 500,70" "ptr button 273 released window" "ptr leave window"
    all_ptr b "ptr enter window at 100,70" "ptr motion 110,75"
    stop
}

p3() {
    name="release outside every surface"
    WIN=$ptr_win start "$cfg" 1
    drive move 150 150 down left move 400 400 up left sleep 100 move 410 410 sleep 100 move 150 150 sleep 150
    stream a "ptr button 272 pressed window" \
        "ptr motion 300,300" "ptr button 272 released window" "ptr leave window" \
        "ptr enter window at 50,50"
    stop
}

# ---- other surface kinds --------------------------------------------------
p4() {
    name="subsurface keeps the grab over its parent and outside"
    WIN="$ptr_win RAYWM_TEST_SUB=1" start "$cfg" 1
    # Subsurface of A: 120..180 x 120..180.
    drive move 130 130 down left move 250 200 move 150 300 up left sleep 200
    has a "ptr enter sub at 10,10"
    stream a "ptr button 272 pressed sub" \
        "ptr motion 130,80" "ptr motion 30,180" "ptr button 272 released sub" "ptr leave sub"
    stop
}

p5() {
    name="layer-shell panel keeps the grab over a window"
    WIN=$ptr_win start "$cfg" 1 panel-ptr
    # The panel: 1280x30 at the top of the output.
    drive move 640 15 down left move 150 150 up left sleep 200
    has panel "ptr enter layer at 640,15"
    stream panel "ptr button 272 pressed layer" \
        "ptr motion 150,150" "ptr button 272 released layer" "ptr leave layer"
    all_ptr a "ptr enter window at 50,50"
    stop
}

p6() {
    name="popup destroyed while its button is held"
    WIN=$ptr_win start "$cfg" 0
    launch a RAYWM_TEST_HOLD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_POPUP=1 RAYWM_TEST_POPUP_KILL=1 RAYWM_TEST_ROUNDS=1
    wait_log a "popup mapped"; sleep 0.3
    # A is at 100,100; its popup at 290..350 x 240..300. The client destroys
    # the popup on the press; the button stays held over A for a while.
    drive_bg move 320 280 down left sleep 100 move 150 150 sleep 1000 up left sleep 200
    sleep 0.7
    if ptr_after a "popup destroyed" | grep -q "enter\|motion\|button"; then fail "A got pointer events while the button was still held"; fi
    drive_wait
    has a "ptr enter popup at 30,40"
    has a "ptr button 272 pressed popup"
    # wlroots sends a leave for the destroyed surface (the client already
    # dropped it), then nothing until the release.
    stream a "popup destroyed" "ptr leave gone" "ptr enter window at 50,50"
    lacks a "ptr button 272 released"
    stop
}

p7() {
    name="window killed while its button is held"
    WIN=$ptr_win start "$cfg" 2
    drive_bg move 150 150 down left move 400 160 sleep 1000 move 600 170 sleep 900 up left sleep 200 move 610 170 sleep 100
    sleep 0.5
    kill -9 "$(cat "$tmp/a.pid")"
    sleep 0.9   # the pointer is now over B, the button still held
    if grep -q "client: ptr " "$tmp/b.log"; then fail "B got pointer events while the button was held"; fi
    drive_wait
    all_ptr b "ptr enter window at 100,70" "ptr motion 110,70"
    # Input still works: a click on B reaches it.
    drive move 600 150 down left up left sleep 150
    has b "ptr button 272 pressed window"
    has b "ptr button 272 released window"
    stop
}

p8() {
    name="scene changes under a held button"
    WIN=$ptr_win start "$cfg" 2
    # Hold on A; a plugin moves A away (+300) and moves B under the cursor.
    drive move 150 200 down left sleep 100 key super down key f10 down key f10 up key f9 down key f9 up key super up \
        sleep 200 move 160 210 up left sleep 200 move 165 215 sleep 150
    # Coordinates follow A's new position (400,100).
    stream a "ptr button 272 pressed window" \
        "ptr motion -240,110" "ptr button 272 released window" "ptr leave window"
    # B, now under the cursor, gets the pointer only after the release.
    all_ptr b "ptr enter window at 60,60" "ptr motion 65,65"
    stop
}

p9() {
    name="output unplugged while a button is held"
    OUTPUTS=2 WIN=$ptr_win start "$cfg" 4
    # D (1300..1500 on the second output) gets the press.
    drive_bg move 1350 150 down left sleep 900 move 700 300 up left sleep 300
    sleep 0.4
    unplug HEADLESS-2
    drive_wait
    has d "ptr button 272 pressed window"
    has d "ptr button 272 released window"
    # Pointer input still works on the remaining output.
    outputs=1
    drive move 150 150 down left up left sleep 150
    has a "ptr button 272 pressed window"
    stop
}

# ---- compositor grabs and wlroots grabs -----------------------------------
p10() {
    name="client-side move and resize keep working"
    WIN="$ptr_win RAYWM_TEST_CSD_MOVE=1 RAYWM_TEST_CSD_RESIZE=1" start "$cfg" 1
    # (pauses: the client asks for the move/resize after it saw the press)
    drive move 150 150 down left sleep 200 move 250 200 up left sleep 200
    dump                                                                      # 1
    expect 1 "view 2 200,150 200x150 focused=true"
    drive move 300 250 down right sleep 200 move 350 280 up right sleep 300
    dump                                                                      # 2
    expect 2 "view 2 200,150 250x180 focused=true"
    has a "csd move requested"
    has a "csd resize requested"
    # The next click is an ordinary one: the seat no longer counts the
    # grabs' buttons as held, so a press and its release both reach A.
    # (Middle button: this client asks for a move on every left press and a
    # resize on every right press, so a left click would race that request.)
    drive move 250 200 sleep 100 key super down key super up down middle up middle sleep 150
    has a "ptr button 274 pressed window"
    has a "ptr button 274 released window"
    stop
}

p11() {
    name="Super+button while a client holds a button goes to the client"
    WIN=$ptr_win start "$cfg" 1
    drive move 150 150 down left key super down down right move 200 200 up right key super up up left sleep 200
    stream a "ptr button 272 pressed window" \
        "ptr button 273 pressed window" "ptr motion 100,100" \
        "ptr button 273 released window" "ptr button 272 released window"
    dump                                                                      # 1
    expect 1 "view 2 100,100 200x150 focused=true"
    stop
}

p12() {
    name="Super+drag does not deliver the press or the release"
    WIN=$ptr_win start "$cfg" 2
    drive move 150 150 key super down down left move 250 250 up left key super up sleep 200 move 255 255 sleep 150
    dump                                                                      # 1
    expect 1 "view 2 200,200 200x150 focused=true"
    lacks a "ptr button"
    # Grab start clears pointer focus; afterwards A is entered again.
    last_ptr a "ptr leave window" "ptr enter window at 50,50" "ptr motion 55,55"
    stop
}

p13() {
    name="xdg_popup grab (wlroots) still routes and dismisses"
    WIN="$ptr_win RAYWM_TEST_POPUP_GRAB=1" start "$cfg" 2
    # Right press on A opens a grabbing popup at 290..350 x 240..300.
    drive move 150 150 down right sleep 300 up right sleep 100
    wait_log a "grabbing popup mapped"
    drive move 320 280 down left up left sleep 200
    has a "ptr enter popup at 30,40"
    has a "ptr button 272 pressed popup"
    # A click on B dismisses the popup; B gets neither the press nor the
    # release of that click, but the pointer afterwards.
    drive move 600 150 down left up left sleep 200 move 605 155 sleep 150
    wait_log a "popup done"
    lacks b "ptr button"
    has b "ptr motion 105,55"
    stop
}

run_scenarios pointer p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12 p13

#!/bin/sh
# Real client capture/relative-pointer/shortcuts requests, headless pixman.
# Requires zig build -Dtest-input -p zig-out/test-input.
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/support/harness.sh"
cfg="$root/tests/captures/init.lua"
helpers="$root/tests/captures/plugins"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
begin() {
    PLUGINS=$helpers start "$cfg" 0
    # Give the headless seat pointer capabilities before the client asks
    # for wl_pointer (there are no physical devices).
    drive move 640 360 sleep 100
}
escape_capture() { drive key ctrl down key alt down key escape down key escape up key alt up key ctrl up sleep 200; }
client_key() { drive sleep 150 key "$1" down key "$1" up sleep 200; }
super_j() { drive key super down key j down key j up key super up sleep 100; }
capture_ready() { wait_log a "frame done"; drive move 640 360 sleep 100; wait_log a "constraint $1"; }

c1() {
    name="locked pointer: raw relative motion, no absolute motion, committed unlock hint"
    begin
    launch a $plain RAYWM_TEST_CONSTRAINT=lock
    capture_ready locked
    drive relative 50 -10 move 900 400 sleep 100
    has a "relative 50.0,-10.0 unaccel=50.0,-10.0"
    lacks a "ptr motion"
    client_key f7
    wait_log a "constraint destroyed"
    drive relative 10 0 sleep 100
    has a "ptr motion 60,60"
    stop
}
c2() {
    name="confined pointer: clip motion to the committed region; release on region shrink"
    begin
    launch a $plain RAYWM_TEST_CONSTRAINT=confine
    capture_ready confined
    drive relative 500 0 sleep 100
    # Region x=20..140, window x=540; integer fixed-point coordinate <=139.
    if grep -E 'ptr motion (1[4-9][0-9]|[2-9][0-9][0-9]),' "$tmp/a.log"; then fail "pointer escaped confinement"; fi
    grep -q 'ptr motion 139,75' "$tmp/a.log" || fail "pointer did not reach confinement edge"
    client_key f8
    wait_log a "constraint unconfined"
    drive move 700 360 sleep 100
    has a "ptr motion 160,75"
    stop
}
c3() {
    name="persistent constraints deactivate on focus loss and reactivate on focus return"
    begin
    launch a $plain RAYWM_TEST_CONSTRAINT=lock
    capture_ready locked
    launch b $plain
    wait_log b "frame done"
    wait_log a "constraint unlocked"
    kill "$(cat "$tmp/b.pid")"
    capture_ready locked
    sleep 0.2
    [ "$(grep -cx 'client: constraint locked' "$tmp/a.log")" -eq 2 ] || fail "persistent constraint did not reactivate"
    stop
}
c4() {
    name="oneshot constraints stay inert after focus loss; destruction is safe"
    begin
    launch a $plain RAYWM_TEST_CONSTRAINT=lock RAYWM_TEST_ONESHOT=1
    capture_ready locked
    launch b $plain
    wait_log b "frame done"
    wait_log a "constraint unlocked"
    kill "$(cat "$tmp/b.pid")"
    sleep 0.2
    [ "$(grep -cx 'client: constraint locked' "$tmp/a.log")" -eq 1 ] || fail "oneshot reactivated"
    client_key f7
    drive move 700 360 sleep 100
    has a "ptr motion 160,75"
    stop
}
c5() {
    name="destroying a locked client clears the native borrow and pointer grab"
    begin
    launch a $plain RAYWM_TEST_CONSTRAINT=lock
    capture_ready locked
    kill "$(cat "$tmp/a.pid")"
    sleep 0.2
    launch b $plain
    wait_log b "frame done"
    drive move 600 330 down left up left sleep 100
    has b "ptr button 272 released window"
    stop
}
c6() {
    name="shortcut inhibitor: focused client gets compositor bindings; escape restores them"
    begin
    launch a $plain RAYWM_TEST_SHORTCUTS=1
    wait_log a "shortcuts active"
    super_j
    has a "kbd key 36 pressed"
    if grep -q '^capture binding$' "$tmp/probe.log"; then fail "inhibited shortcut ran"; fi
    escape_capture
    wait_log a "shortcuts inactive"
    super_j
    [ "$(grep -c '^capture binding$' "$tmp/probe.log")" -eq 1 ] || fail "shortcut did not resume"
    stop
}
c7() {
    name="inhibitors follow keyboard focus; unfocused clients cannot capture bindings"
    begin
    launch a $plain RAYWM_TEST_SHORTCUTS=1
    wait_log a "shortcuts active"
    launch b $plain
    wait_log b "frame done"
    wait_log a "shortcuts inactive"
    super_j
    [ "$(grep -c '^capture binding$' "$tmp/probe.log")" -eq 1 ] || fail "unfocused client inhibited bindings"
    stop
}
c8() {
    name="plugin warps respect locks; Ctrl+Alt+Escape releases persistent capture"
    begin
    launch a $plain RAYWM_TEST_CONSTRAINT=lock
    capture_ready locked
    drive key super down key w down key w up key super up relative 20 0 sleep 100
    lacks a "ptr leave"
    lacks a "ptr motion"
    escape_capture
    wait_log a "constraint unlocked"
    drive move 700 360 sleep 100
    has a "ptr motion 160,75"
    [ "$(grep -cx 'client: constraint locked' "$tmp/a.log")" -eq 1 ] || fail "capture reactivated before focus changed"
    stop
}
c9() {
    name="confinement clips the segment without jumping across a region hole"
    begin
    launch a $plain RAYWM_TEST_CONSTRAINT=confine RAYWM_TEST_CONSTRAINT_HOLE=1
    wait_log a "frame done"
    drive move 570 360 sleep 100
    wait_log a "constraint confined"
    drive relative 100 0 sleep 100
    has a "ptr motion 59,75"
    lacks a "ptr motion 130,75"
    stop
}
c10() {
    name="session lock deactivates client pointer and keyboard captures"
    begin
    launch a $plain RAYWM_TEST_CONSTRAINT=lock RAYWM_TEST_SHORTCUTS=1
    capture_ready locked
    wait_log a "shortcuts active"
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" \
        "$bin/raywm-test-lock" >"$tmp/l.log" 2>&1 &
    echo $! >"$tmp/l.pid"
    wait_log l "locked"
    wait_log a "constraint unlocked"
    wait_log a "shortcuts inactive"
    drive move 300 300 down left up left sleep 100
    grep -q 'lock: ptr button 272 pressed' "$tmp/l.log" || fail "lock surface received no click"
    lacks a "ptr button 272"
    client_key f12
    wait_log l "unlocked"
    stop
}

run_scenarios captures c1 c2 c3 c4 c5 c6 c7 c8 c9 c10

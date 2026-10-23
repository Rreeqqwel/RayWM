#!/bin/sh
set -eu
bin=$(cd "${1:-zig-out/effects/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/support/harness.sh"
cfg="$root/tests/effects/init.lua"
plugins="$root/tests/effects/plugins"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
super_key() { drive key super down key "$1" down key "$1" up key super up sleep 100; }
capture() { env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" grim "$tmp/$1.png"; }
pixel() { python3 "$root/tests/support/png_check.py" "$tmp/$1.png" --pixel "$2" || fail "pixel $1 $2"; }
e1() {
    name="plugin-owned rectangles update, ignore input, and clean up on reload"
    WIN=$plain PLUGINS=$plugins start "$cfg" 1
    capture red
    pixel red 575,325,ff0000
    drive move 575 325 down left up left sleep 100
    has a "ptr button 272 released window"
    super_key f7
    capture green
    pixel green 575,325,00ff00
    # Removal from configuration invokes ownership cleanup.
    printf 'raywm.load("probe")\nraywm.load("binds")\n' >"$tmp/config/raywm/init.lua"
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 200
    capture removed
    python3 - "$root/tests/support" "$tmp/green.png" "$tmp/removed.png" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from png_check import decode
a,b=decode(sys.argv[2]),decode(sys.argv[3])
assert a[3][325][575*a[2]:575*a[2]+3] != b[3][325][575*b[2]:575*b[2]+3]
PY
    stop
}
e2() {
    name="native tweens preserve layout geometry, finish, cancel and interrupt"
    WIN=$plain PLUGINS=$plugins start "$cfg" 1
    super_key f8
    capture original
    super_key f9
    sleep 0.9
    capture faded
    pixel faded 640,360,000000
    dump
    expect 1 "view 2 540,285 200x150 focused=true"
    super_key f10
    capture restored
    python3 - "$root/tests/support" "$tmp/original.png" "$tmp/restored.png" <<'PY'
import sys
sys.path.insert(0,sys.argv[1])
from png_check import decode
a,b=decode(sys.argv[2]),decode(sys.argv[3])
assert a == b
PY
    super_key f9
    super_key t
    sleep 0.3
    capture interrupted
    python3 - "$root/tests/support" "$tmp/original.png" "$tmp/interrupted.png" <<'PY'
import sys
sys.path.insert(0,sys.argv[1])
from png_check import decode
assert decode(sys.argv[2]) == decode(sys.argv[3])
PY
    kill "$(cat "$tmp/a.pid")"
    sleep 0.2
    stop
}
e3() {
    name="close snapshots retain client buffers and retire after the transition"
    WIN=$plain PLUGINS=$plugins start "$root/tests/effects/transitions.lua" 1
    sleep 0.9
    capture before
    kill "$(cat "$tmp/a.pid")"
    sleep 0.1
    capture closing
    sleep 0.9
    capture after
    pixel after 640,360,000000
    python3 - "$root/tests/support" "$tmp/closing.png" <<'PY'
import sys
sys.path.insert(0,sys.argv[1])
from png_check import decode
image=decode(sys.argv[2]); pixel=image[3][360][640*image[2]:640*image[2]+3]
assert any(pixel), 'close snapshot was not rendered'
PY
    stop
}
e4() {
    name="workspace-out snapshots survive hiding and workspace-in returns to normal"
    WIN=$plain PLUGINS=$plugins start "$root/tests/effects/transitions.lua" 1
    sleep 0.9
    capture before
    super_key 2
    capture outgoing
    python3 - "$root/tests/support" "$tmp/outgoing.png" <<'PY'
import sys
sys.path.insert(0,sys.argv[1])
from png_check import decode
image=decode(sys.argv[2]); assert any(image[3][360][640*image[2]:640*image[2]+3])
PY
    sleep 0.9
    capture hidden
    pixel hidden 640,360,000000
    super_key 1
    sleep 0.9
    capture back
    python3 - "$root/tests/support" "$tmp/before.png" "$tmp/back.png" <<'PY'
import sys
sys.path.insert(0,sys.argv[1])
from png_check import decode
assert decode(sys.argv[2]) == decode(sys.argv[3])
PY
    stop
}
e5() {
    name="workspace events retain ids when a focus callback destroys the old workspace"
    WIN=$plain PLUGINS=$plugins start "$root/tests/effects/reentrant.lua" 1
    super_key t
    [ -e "$tmp/reentrant-ok" ] || fail "workspace event used a destroyed native pointer"
    stop
}
e6() {
    name="shipped visual indicator follows focus and cleans up on reload"
    WIN="$plain RAYWM_TEST_PATTERN=1" PLUGINS=$plugins start "$root/tests/effects/indicator.lua" 1
    capture indicator
    pixel indicator 1263,15,80c0ff
    printf 'raywm.load("probe")\nraywm.load("binds")\n' >"$tmp/config/raywm/init.lua"
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 200
    capture removed
    pixel removed 1263,15,00ff00
    stop
}
e7() {
    name="initial rule opacity survives deferred configure and scene reveal"
    WIN="$plain RAYWM_TEST_PATTERN=1" RULES="$root/tests/effects/opacity-rules.lua" \
        start "$root/tests/rules/init.lua" 1
    capture opacity
    pixel opacity 100,100,800000
    stop
}
run_scenarios effects e1 e2 e3 e4 e5 e6 e7

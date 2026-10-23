#!/bin/sh
# Real-client taskbar protocol exchanges, lifecycle and hotplug. Isolated
# headless pixman by default; no input reaches the user's desktop.
#   zig build -Dtest-input -p zig-out/taskbar
#   tests/taskbar.sh zig-out/taskbar/bin
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-taskbar" ] || { echo "taskbar: build with -Dtest-input"; exit 2; }
. "$root/tests/support/harness.sh"
cfg="$root/tests/taskbar/init.lua"
plugins="$root/tests/taskbar/plugins"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1 RAYWM_TEST_CLOSE=1"
super_key() { drive key super down key "$1" down key "$1" up key super up sleep 250; }
tool() {
    n=$1; shift
    env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" \
        "$@" >"$tmp/$n.log" 2>&1 || fail "tool $*"
}
tb() { n=$1; shift; tool "$n" "$bin/raywm-test-taskbar" "$@"; }
watch() {
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" \
        "$bin/raywm-test-taskbar" watch >"$tmp/watch.log" 2>&1 &
    echo $! >"$tmp/watch.pid"
    wait_log watch "taskbar: ready"
}
line() { grep "taskbar: wlr app=$2 " "$tmp/$1.log" | tail -1; }
contains() { grep -qF "$2" "$tmp/$1.log" || fail "$1: missing '$2'"; }

t1() {
    name="wlr and ext list metadata, parent, focus, capabilities and stop"
    WIN="$plain RAYWM_TEST_APP_ID=alpha RAYWM_TEST_TITLE=Alpha RAYWM_TEST_CHILD=1" PLUGINS=$plugins start "$cfg" 1 panel
    wait_log a "child mapped"
    sleep 0.2
    tb initial snapshot
    contains initial "wlr app=alpha title=Alpha"
    contains initial "ext app=alpha title=Alpha identifier="
    contains initial "wlr app=raywm-test-child title=raywm-test-child"
    line initial raywm-test-child | grep -q 'parent=alpha' || fail "child parent missing"
    [ "$(grep -c '^taskbar: ext app=' "$tmp/initial.log")" -ge 2 ] || fail "ext list missing windows"
    contains initial "group output=HEADLESS-1 caps=0"
    contains initial "ws name=1 output=HEADLESS-1 state=1 caps=1"
    contains initial "ws name=2 output=HEADLESS-1 state=0 caps=1"
    tb finished stop
    contains finished "finished 3"
    stop
    WIN="$plain RAYWM_TEST_APP_ID=alpha RAYWM_TEST_METADATA_KEYS=1" PLUGINS=$plugins start "$cfg" 1
    watch
    drive sleep 250 key f5 down key f5 up sleep 250
    wait_log a "metadata changed"
    wait_log watch "wlr app=changed-app title=Changed title"
    wait_log watch "ext app=changed-app title=Changed title"
    stop
}

t2() {
    name="taskbar maximize, fullscreen, minimize, restore, activation and close"
    WIN="$plain RAYWM_TEST_APP_ID=alpha" PLUGINS=$plugins start "$cfg" 1
    launch b $plain RAYWM_TEST_APP_ID=beta
    wait_log b "frame done"
    tb maximum maximize alpha
    line maximum alpha | grep -q 'max=true' || fail "maximize not reported"
    tb normal unmaximize alpha
    line normal alpha | grep -q 'max=false' || fail "unmaximize not reported"
    tb full fullscreen alpha
    line full alpha | grep -q 'full=true' || fail "fullscreen not reported"
    wait_log a "fullscreen on 1280x720"
    tb unfull unfullscreen alpha
    line unfull alpha | grep -q 'full=false' || fail "unfullscreen not reported"
    tb minimized minimize alpha
    line minimized alpha | grep -q 'min=true' || fail "minimize not reported"
    tb restored restore alpha
    line restored alpha | grep -q 'min=false' || fail "restore not reported"
    tb activated activate alpha
    line activated alpha | grep -q 'active=true' || fail "activate did not focus alpha"
    watch
    tb closed close alpha
    wait_log a "closing"
    wait_log watch "wlr closed alpha"
    wait_log watch "ext closed alpha"
    contains watch "wlr stale requests sent"
    tb after snapshot
    if grep -q 'app=alpha ' "$tmp/after.log"; then fail "closed window still listed"; fi
    stop
}

t3() {
    name="ext-workspace activation and taskbar activation restore hidden windows"
    WIN="$plain RAYWM_TEST_APP_ID=alpha" PLUGINS=$plugins start "$cfg" 1
    tb switch workspace 2 HEADLESS-1
    contains switch "ws name=2 output=HEADLESS-1 state=1 caps=1"
    has a "deactivated"
    launch b $plain RAYWM_TEST_APP_ID=beta
    wait_log b "frame done"
    tb hidden minimize alpha
    tb activated activate alpha
    contains activated "ws name=1 output=HEADLESS-1 state=1 caps=1"
    line activated alpha | grep -q 'min=false active=true' || fail "hidden minimized window not restored/focused"
    tb unsupported unsupported 1 HEADLESS-1
    contains unsupported "ws name=1 output=HEADLESS-1 state=1 caps=1"
    [ "$(grep '^taskbar: ws name=' "$tmp/unsupported.log" | sort -u | wc -l)" -eq 9 ] || fail "unsupported request changed workspaces"
    stop
}

t4() {
    name="workspace rename, urgency, creation, removal, reload and stale handles"
    WIN="$plain RAYWM_TEST_APP_ID=alpha" PLUGINS=$plugins start "$cfg" 1
    watch
    super_key f9
    wait_log watch "ws name=two output=HEADLESS-1"
    super_key f7
    wait_log watch "ws name=1 output=HEADLESS-1 state=3"
    super_key f10
    wait_log watch "ws removed 9"
    super_key f6
    wait_log watch "ws name=extra output=HEADLESS-1"
    tb before snapshot
    contains before "ws name=extra output=HEADLESS-1 state=0 caps=1"
    # The shipped plugin adopts all surviving workspaces across reload.
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 500
    tb after snapshot
    contains after "ws name=extra output=HEADLESS-1 state=0 caps=1"
    # Removing the workspace plugins dissolves their unadopted workspaces.
    cp "$root/tests/workspaces/noworkspaces.lua" "$tmp/config/raywm/init.lua"
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 400
    wait_log watch "ws removed extra"
    tb dissolved snapshot
    if grep -q '^taskbar: ws name=' "$tmp/dissolved.log"; then fail "unadopted workspace still listed"; fi
    stop
}

t5() {
    name="per-output groups, spanning windows, output unplug and replug"
    OUTPUTS=2 WIN="$plain RAYWM_TEST_APP_ID=alpha" PLUGINS=$plugins start "$cfg" 1
    tb initial snapshot
    contains initial "group output=HEADLESS-1 caps=0"
    contains initial "group output=HEADLESS-2 caps=0"
    watch
    super_key f8
    tb spanning snapshot
    line spanning alpha | grep -q 'outputs=2' || fail "spanning window lacks output membership"
    unplug HEADLESS-2
    sleep 0.3
    wait_log watch "group removed"
    tb gone snapshot
    if grep -q 'group output=HEADLESS-2' "$tmp/gone.log"; then fail "removed output group remains"; fi
    line gone alpha | grep -q 'outputs=1' || fail "removed output remains on window"
    [ "$(grep '^taskbar: ws name=' "$tmp/gone.log" | tail -18 | wc -l)" -eq 18 ] || fail "workspace lost on unplug"
    plug
    sleep 0.4
    tb added snapshot
    [ "$(grep -c '^taskbar: group output=' "$tmp/added.log")" -eq 2 ] || fail "new output has no group"
    stop
}

t6() {
    name="client disconnect, window destruction and remap use new identifiers"
    PLUGINS=$plugins start "$cfg" 0
    watch
    # A window maps twice, recreating its toplevel on the same xdg_surface.
    launch a RAYWM_TEST_APP_ID=cycling RAYWM_TEST_ROUNDS=2
    wait_log a "done"
    wait_log watch "ext closed cycling"
    sleep 0.2
    [ "$(grep '^taskbar: ext app=cycling ' "$tmp/watch.log" | sed 's/.*identifier=//' | sort -u | wc -l)" -eq 2 ] || fail "remap reused ext identifier"
    [ "$(grep -c '^taskbar: wlr closed cycling' "$tmp/watch.log")" -eq 2 ] || fail "remap did not close both wlr handles"
    kill "$(cat "$tmp/watch.pid")"
    i=0
    while [ "$i" -lt 12 ]; do tb disconnect snapshot; i=$((i + 1)); done
    launch b $plain RAYWM_TEST_APP_ID=after-disconnect
    wait_log b "frame done"
    tb after snapshot
    contains after "wlr app=after-disconnect"
    stop
}

t7() {
    name="sandboxed clients cannot enumerate taskbars or workspace globals"
    PLUGINS=$plugins start "$cfg" 0
    tool sandbox "$bin/raywm-test-probe" sandbox
    for global in zwlr_foreign_toplevel_manager_v1 ext_foreign_toplevel_list_v1 ext_workspace_manager_v1; do
        contains sandbox "normal sees $global"
        if grep -qF "sandboxed sees $global" "$tmp/sandbox.log"; then fail "sandbox sees $global"; fi
    done
    stop
}

t8() {
    name="taskbar and workspace requests do not change the locked session"
    WIN="$plain RAYWM_TEST_APP_ID=alpha" PLUGINS=$plugins start "$cfg" 1
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" \
        "$bin/raywm-test-lock" >"$tmp/locker.log" 2>&1 &
    wait_log locker "locked"
    tb minimize minimize alpha
    line minimize alpha | grep -q 'min=false' || fail "taskbar minimized while locked"
    tb full fullscreen alpha
    line full alpha | grep -q 'full=false' || fail "taskbar fullscreen while locked"
    tb switched workspace 2 HEADLESS-1
    contains switched "ws name=1 output=HEADLESS-1 state=1 caps=1"
    tb close close alpha
    lacks a "closing"
    drive sleep 250 key f12 down key f12 up sleep 250
    wait_log locker "unlocked"
    stop
}

run_scenarios taskbar t1 t2 t3 t4 t5 t6 t7 t8

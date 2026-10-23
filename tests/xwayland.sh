#!/bin/sh
set -eu
bin=$(cd "${1:-zig-out/continuation/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/support/harness.sh"
# wlroots 0.20 XWM may process an already queued property event after its
# X client destroys that window. Keep these diagnostics visible; other
# errors still fail, and all state/clipboard assertions remain mandatory.
EXPECTED_LOG_ERRORS='\[xwayland/xwm.c:[0-9]+\] (Failed to get window property|xcb error: op DeleteProperty \(no minor\), code Window )'
cfg="$root/tests/windows/floating.lua"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
super_key() { drive key super down key "$1" down key "$1" up key super up sleep 250; }
xlaunch() {
    display=$(sed -n 's/.*lazy Xwayland display \(:[0-9]*\).*/\1/p' "$tmp/raywm.log" | tail -1)
    [ -n "$display" ] || { fail "no private X display"; return; }
    env -i PATH="$PATH" DISPLAY="$display" XDG_RUNTIME_DIR="$tmp" "$bin/raywm-test-x11" "$tmp/command" >"$tmp/x.log" 2>&1 &
    echo $! >"$tmp/x.pid"
    wait_log x "x11: mapped"
    sleep 0.3
}
command() { printf '%s\n' "$*" >"$tmp/command"; sleep 0.35; }
xstop() { if kill -0 "$(cat "$tmp/x.pid")" 2>/dev/null; then command quit; sleep 0.2; fi; stop; }
xhas() { grep -qF "$1" "$tmp/x.log" || fail "X11: missing $1"; }
x1() {
    name="Xwayland mapping, buffer resize, fullscreen/maximize and native metadata"
    start "$cfg" 0
    xlaunch
    dump
    expect 1 "view 2 540,285 200x150 focused=true"
    expect 1 "backend 2 xwayland=true pid=$(cat "$tmp/x.pid")"
    xhas "x11: focus in"
    command resize
    dump
    expect 2 "view 2 300,200 350x220 focused=true"
    command fullscreen 1
    dump
    expect 3 "state 2 floating=false fullscreen=true maximized=false visible=true managed=false ws=0 output=1"
    expect 3 "view 2 0,0 1280x720 focused=true"
    command fullscreen 0
    command maximize 1
    dump
    expect 4 "state 2 floating=false fullscreen=false maximized=true visible=true managed=false ws=0 output=1"
    command maximize 0
    dump
    expect 5 "view 2 300,200 350x220 focused=true"
    xstop
}
x2() {
    name="Xwayland focus, interactive move and resize, close"
    start "$cfg" 0
    xlaunch
    drive move 600 330 key super down down left move 650 360 up left key super up sleep 300
    dump
    expect 1 "view 2 590,315 200x150 focused=true"
    drive move 750 430 key super down down right move 800 460 up right key super up sleep 300
    dump
    grep -qE '^view 2 590,315 250x(179|180) focused=true$' "$tmp/probe.log" || fail "resize geometry"
    super_key q
    wait_log x "x11: closed"
    launch a $plain
    wait_log a "frame done"
    drive move 600 330 down left up left sleep 100
    has a "ptr button 272 released window"
    xstop
}
x3() {
    name="Xwayland workspaces, minimize/restore and override-redirect visibility"
    PLUGINS="$root/tests/shell/plugins" start "$root/tests/shell/init.lua" 0
    xlaunch
    command minimize
    dump
    expect 1 "shell 11 minimized=true urgent=false decoration=nil"
    drive key super down key shift down key n down key n up key shift up key super up sleep 300
    command menu
    drive move 750 230 down left up left sleep 200
    xhas "x11: button 1 menu"
    super_key 2
    dump
    expect 2 "state 11 floating=false fullscreen=false maximized=false visible=false managed=true ws=2 output=1"
    launch a $plain
    wait_log a "frame done"
    drive move 750 230 down left up left sleep 150
    has a "ptr button 272 released window"
    super_key 1
    command unmenu
    xstop
}
x4() {
    name="X11 and Wayland clipboard bytes in both directions"
    start "$cfg" 0
    xlaunch
    command copy
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" timeout 5 wl-paste --no-newline >"$tmp/copied"
    [ "$(cat "$tmp/copied")" = raywm-x11-clipboard ] || fail "X11 to Wayland bytes"
    printf '%s' raywm-wayland-clipboard | env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" wl-copy
    command paste
    wait_log x "x11: pasted raywm-wayland-clipboard"
    xstop
}
x5() {
    name="Xwayland early crash recovery preserves Wayland windows"
    WLR_XWAYLAND="$root/tests/support/xwayland-wrapper.sh" start "$cfg" 0
    launch a $plain
    wait_log a "frame done"
    xlaunch
    kill -KILL "$(cat "$tmp/xwayland.pid")"
    sleep 1
    xlaunch
    xhas "x11: mapped"
    dump
    grep -q 'view 2 ' "$tmp/probe.log" || fail "Wayland window lost"
    xstop
}
x6() {
    name="Xwayland fullscreen survives output hotplug and a long-running X server restarts"
    OUTPUTS=2 WLR_XWAYLAND="$root/tests/support/xwayland-wrapper.sh" start "$cfg" 0
    xlaunch
    command fullscreen 1
    unplug HEADLESS-2
    sleep 0.3
    dump
    expect 1 "state 3 floating=false fullscreen=true maximized=false visible=true managed=false ws=0 output=2"
    sleep 5.2
    kill -KILL "$(cat "$tmp/xwayland.pid")"
    sleep 0.4
    xlaunch
    xhas "x11: mapped"
    xstop
}
run_scenarios xwayland x1 x2 x3 x4 x5 x6

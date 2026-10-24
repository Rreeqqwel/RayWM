#!/bin/sh
# raywm.conf (src/conf.zig): `raywm -t`, the loading order (defaults,
# system file, user file), every setting taking effect in a headless
# session with real input events, reload (valid, invalid, repeated) and
# compatibility with plugins written before raywm.conf.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=substring] tests/conf.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "conf: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
. "$root/tests/support/harness.sh"

fx="$root/tests/conf"
tiled="$fx/tiled.lua"
floating="$fx/floating.lua"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
# Diagnostics this suite provokes on purpose (log.err of rejected files).
conf_errors='error\(conf\)'
reload() { drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 400; }
super_l() { drive key super down key l down key l up key super up sleep 300; }
# The compositor process (start() runs it under timeout).
raywm_pid() { pgrep -P "$pid" -x raywm; }
rss_kb() { awk '/^VmRSS:/ {print $2}' "/proc/$(raywm_pid)/status"; }

# raywm -t: no compositor, only the files. Each case: <expected status>
# <output pattern> <files...> (user file, then optional system file).
check_t() {
    want=$1; pattern=$2; user=$3; system=${4:-}
    d=$(mktemp -d)
    [ -n "$user" ] && cp "$user" "$d/raywm.conf"
    st=0
    env -i PATH="$PATH" HOME="$d" RAYWM_SYSTEM_CONF="$system" "$bin/raywm" -t -c "$d/init.lua" >"$d/out" 2>&1 || st=$?
    if [ "$st" -ne "$want" ] || ! grep -qE "$pattern" "$d/out"; then
        fail "raywm -t ${user##*/} ${system##*/}: status $st (want $want), pattern '$pattern'"
        cat "$d/out"
    fi
    rm -rf "$d"
}

t1() {
    name="raywm -t: defaults, valid, unknown keys, errors with line numbers, layers"
    scenarios=$((scenarios + 1)); before=$failures
    check_t 0 "^appearance.inner_gaps = 8$" ""
    check_t 0 "^configuration OK$" ""
    check_t 0 "^appearance.border_active = #ff0000ff$" "$fx/gaps.conf"
    check_t 0 "^appearance.border_inactive = #202020ff$" "$fx/gaps.conf"
    check_t 0 "^configuration OK$" "$root/config/raywm.conf"
    check_t 0 "raywm.conf:3: unknown key 'corner_radius' in \[appearance\] ignored" "$fx/unknown.conf"
    check_t 0 "raywm.conf:4: unknown section \[plugins\] ignored" "$fx/unknown.conf"
    check_t 0 "^appearance.outer_gaps = 4$" "$fx/unknown.conf"
    check_t 1 "raywm.conf:3: \[appearance\] outer_gaps = fifty: expected a whole number" "$fx/broken.conf"
    # The rejected file changes nothing at all (inner_gaps = 50 on line 2 too).
    check_t 1 "^appearance.inner_gaps = 8$" "$fx/broken.conf"
    check_t 1 "configuration has errors" "$fx/broken.conf"
    # Defaults < system < user, key by key.
    check_t 0 "^appearance.inner_gaps = 6$" "$fx/user-over-system.conf" "$fx/system.conf"
    check_t 0 "^appearance.outer_gaps = 30$" "$fx/user-over-system.conf" "$fx/system.conf"
    check_t 0 "^appearance.border_inactive = #101010ff$" "$fx/user-over-system.conf" "$fx/system.conf"
    # A broken system file is reported; the user file still applies.
    check_t 1 "^appearance.outer_gaps = 30$" "$fx/user-over-system.conf" "$fx/broken.conf"
    check_t 0 "^appearance.inner_gaps = 8$" "" "/nonexistent/raywm.conf"
    if [ "$failures" -eq "$before" ]; then echo "ok   [$name]"; fi
}

t2() {
    name="gaps from raywm.conf reach dwindle (borders: tests/focus_test.lua)"
    CONF="$fx/gaps.conf" WIN=$plain start "$tiled" 2
    dump                                                                      # 1
    expect 1 "view 2 20,20 619x680 focused=false"
    expect 1 "view 3 641,20 619x680 focused=true"
    grep -q "info(conf): loaded .*/raywm.conf" "$tmp/raywm.log" || fail "raywm.conf load not logged"
    stop
}

t3() {
    name="reload applies a changed raywm.conf, keeps the previous one when it is broken"
    EXPECTED_LOG_ERRORS=$conf_errors # read by stop()
    CONF="$fx/gaps.conf" WIN=$plain start "$tiled" 2
    cp "$fx/nogaps.conf" "$tmp/config/raywm/raywm.conf"
    reload
    dump                                                                      # 1
    expect 1 "view 2 0,0 640x720 focused=false"
    expect 1 "view 3 640,0 640x720 focused=true"
    cp "$fx/broken.conf" "$tmp/config/raywm/raywm.conf"
    reload
    dump                                                                      # 2
    expect 2 "view 2 0,0 640x720 focused=false"
    expect 2 "view 3 640,0 640x720 focused=true"
    grep -q "raywm.conf:3: \[appearance\] outer_gaps = fifty: expected a whole number" "$tmp/raywm.log" ||
        fail "no line-numbered diagnostic for the broken file"
    grep -q "keeping the previous settings" "$tmp/raywm.log" || fail "broken file was not reported as ignored"
    # Lua was reloaded once per reload, with the plugins loaded once each.
    [ "$(grep -c 'loaded plugin dwindle' "$tmp/raywm.log")" -eq 3 ] || fail "dwindle loaded $(grep -c 'loaded plugin dwindle' "$tmp/raywm.log") times, expected 3"
    lacks raywm "already bound"
    # Recovery: the fixed file applies on the next reload.
    cp "$fx/gaps.conf" "$tmp/config/raywm/raywm.conf"
    reload
    dump                                                                      # 3
    expect 3 "view 2 20,20 619x680 focused=false"
    stop
    EXPECTED_LOG_ERRORS=
}

t4() {
    name="repeated reloads: no growth of plugins, bindings or memory"
    CONF="$fx/gaps.conf" WIN=$plain start "$tiled" 2
    fast_reloads() {
        n=0
        while [ $n -lt "$1" ]; do
            drive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 60
            n=$((n + 1))
        done
        drive sleep 400
    }
    # The first reloads warm up malloc's arenas and Lua's string tables
    # (about 1.3 MiB, then flat); measured after that.
    fast_reloads 10
    first=$(rss_kb)
    fast_reloads "${RELOADS:-31}"
    last=$(rss_kb)
    growth=$((last - first))
    echo "     RSS after 10 reloads: ${first} kB, after $((10 + ${RELOADS:-31})): ${last} kB (growth ${growth} kB)"
    # A leak of 16 KiB per reload would exceed this.
    [ "$growth" -lt 512 ] || fail "RSS grew by $growth kB over ${RELOADS:-31} reloads"
    loads=$((1 + 10 + ${RELOADS:-31}))
    [ "$(grep -c 'loaded plugin dwindle' "$tmp/raywm.log")" -eq $loads ] || fail "dwindle loaded $(grep -c 'loaded plugin dwindle' "$tmp/raywm.log") times, expected $loads"
    [ "$(grep -c 'info(conf): loaded .*/raywm.conf' "$tmp/raywm.log")" -eq $loads ] || fail "raywm.conf not read once per load"
    dump                                                                      # 1
    expect 1 "view 2 20,20 619x680 focused=false"
    expect 1 "view 3 641,20 619x680 focused=true"
    lacks raywm "already bound"
    stop
}

t5() {
    name="focus_new_windows = false: a new window does not take focus"
    CONF="$fx/nofocus.conf" WIN=$plain start "$tiled" 1
    launch b $plain
    wait_log b "hold resized 628x704"
    dump                                                                      # 1
    expect 1 "view 2 8,8 628x704 focused=true"
    expect 1 "view 3 644,8 628x704 focused=false"
    lacks b "client: activated"
    stop
}

t6() {
    name="mouse_modifier = alt: Alt+drag moves a floating window, Super+drag does not"
    CONF="$fx/alt.conf" WIN=$plain start "$floating" 1
    dump                                                                      # 1
    expect 1 "view 2 540,285 200x150 focused=true"
    drive move 640 360 key alt down down left move 700 375 up left key alt up sleep 200
    dump                                                                      # 2
    expect 2 "view 2 600,300 200x150 focused=true"
    drive move 640 360 key super down down left move 400 200 up left key super up sleep 200
    dump                                                                      # 3
    expect 3 "view 2 600,300 200x150 focused=true"
    # Super+click went to the client, as a normal click.
    has a "ptr button 272 pressed window"
    stop
}

t7() {
    name="mouse_modifier default: Super+drag still moves (unchanged behaviour)"
    WIN=$plain start "$floating" 1
    drive move 640 360 key super down down left move 700 375 up left key super up sleep 200
    dump                                                                      # 1
    expect 1 "view 2 600,300 200x150 focused=true"
    stop
}

t8() {
    name="focus_follows_mouse: entering a window focuses it, once per entry"
    CONF="$fx/ffm.conf" WIN=$plain start "$tiled" 2
    drive move 300 300 sleep 200
    dump                                                                      # 1
    expect 1 "view 2 8,8 628x704 focused=true"
    # Keyboard focus moved away while the pointer stays inside a: moving
    # within a does not take it back.
    super_l
    drive move 320 310 sleep 200
    dump                                                                      # 2
    expect 2 "view 3 644,8 628x704 focused=true"
    drive move 900 300 sleep 200
    drive move 300 300 sleep 200
    dump                                                                      # 3
    expect 3 "view 2 8,8 628x704 focused=true"
    stop
}

t9() {
    name="focus_follows_mouse off (default): moving the pointer changes no focus"
    WIN=$plain start "$tiled" 2
    drive move 300 300 sleep 200
    dump                                                                      # 1
    expect 1 "view 3 644,8 628x704 focused=true"
    stop
}

t10() {
    name="xwayland = false: Xwayland is not started; changing it needs a restart"
    CONF="$fx/noxwayland.conf" WIN=$plain start "$floating" 0
    grep -q "Xwayland disabled (raywm.conf general.xwayland)" "$tmp/raywm.log" || fail "Xwayland not disabled"
    lacks raywm "lazy Xwayland display"
    rm "$tmp/config/raywm/raywm.conf"
    reload
    grep -q "general.xwayland changed: takes effect after restarting RayWM" "$tmp/raywm.log" || fail "restart-only change not reported"
    lacks raywm "lazy Xwayland display"
    stop
}

t11() {
    name="system raywm.conf below the user's, key by key"
    COMPOSITOR_ENV="RAYWM_SYSTEM_CONF=$fx/system.conf" CONF="$fx/user-over-system.conf" WIN=$plain start "$tiled" 2
    dump                                                                      # 1
    expect 1 "view 2 30,30 607x660 focused=false"
    expect 1 "view 3 643,30 607x660 focused=true"
    stop
}

t12() {
    name="v0.2.1 plugins (no raywm.settings) keep working next to raywm.conf"
    CONF="$fx/gaps.conf" PLUGINS="$root/tests/compat/v0.2.1/plugins" WIN=$plain start "$tiled" 2
    dump                                                                      # 1
    # Their own option tables (8 px) apply; raywm.conf's gaps do not.
    expect 1 "view 2 8,8 628x704 focused=false"
    expect 1 "view 3 644,8 628x704 focused=true"
    super_l
    drive key super down key h down key h up key super up sleep 300
    dump                                                                      # 2
    expect 2 "view 2 8,8 628x704 focused=true"
    stop
}

t13() {
    name="no raywm.conf at all: built-in defaults (the v0.2.1 behaviour)"
    WIN=$plain start "$tiled" 2
    dump                                                                      # 1
    expect 1 "view 2 8,8 628x704 focused=false"
    expect 1 "view 3 644,8 628x704 focused=true"
    lacks raywm "info(conf)"
    lacks raywm "error(conf)"
    stop
}

run_scenarios conf t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 t12 t13

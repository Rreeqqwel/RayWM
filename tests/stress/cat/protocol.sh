#!/bin/sh
# Wayland/Xwayland protocol torture:
#   profiles        concurrent chaos clients, each hammering one area
#                   (popups, titles/app_ids, states, commit bursts, layer
#                   surfaces, role changes and subsurfaces) next to two
#                   passive taskbars; nobody valid is disconnected, the
#                   audit holds afterwards
#   taskbar-flood   uncapped clients (one fullscreen) and two taskbars: the
#                   v0.2.1 fix holds, taskbars get events per change, not
#                   per commit
#   invalid-storm   dozens of clients each ending with a protocol violation,
#                   next to valid ones: only the violators are disconnected
#   kill-pending    clients SIGKILLed at random moments while they hold
#                   unacknowledged configures, popups and subsurfaces
#   outputs         outputs unplugged and plugged in repeatedly under load
#   xwayland        X11 clients toggling fullscreen and killed mid-way, and
#                   the X server itself killed, next to Wayland clients
. "$(dirname "$0")/../lib.sh"
seed=$STRESS_SEED
ops=$(level_pick 400 2000 5000)
expected='\[chaos\]|\[audit\]'

settle_all() { # LOG-PREFIX COUNT: every client settled (or failed: reported)
    i=0
    while [ $i -lt "$2" ]; do
        wait_for "$1$i.log" 'settled\|FAIL\|disconnected as expected\|NOT disconnected' 180 || fail "client $1$i did not settle"
        grep -q 'FAIL\|NOT disconnected' "$dir/$1$i.log" && fail "client $1$i: $(grep -m1 'FAIL\|NOT disconnected' "$dir/$1$i.log")"
        i=$((i + 1))
    done
}
audit_now() { # NAME EXPECTED_VIEWS
    echo "$2" >"$dir/expect-views"
    rm -f "$dir/audit.txt"; : >"$dir/audit-request"
    wait_for audit.txt 'audit done' 10 || { fail "audit ($1) did not run"; return; }
    grep -q VIOLATION "$dir/audit.txt" && fail "audit ($1): $(grep -c VIOLATION "$dir/audit.txt") violation(s), first: $(grep -m1 VIOLATION "$dir/audit.txt")"
    cp "$dir/audit.txt" "$dir/audit-$1.txt"
}
perf_value() { sed -n "s/.* $2=\([0-9]*\).*/\1/p" "$dir/$1.log" | tail -1; }

c_profiles() {
    case_begin profiles "$seed"
    start "$stress_root/config/lifecycle.lua" 1 || { case_end; return; }
    : >"$dir/stop" # no compositor-side chaos here: the clients are the load
    for t in 1 2; do client "watch$t.log" "$BIN/raywm-test-perf" watch $(level_pick 12 40 90); done
    i=0
    for p in "new,ack,popup,unpopup,destroy" "new,ack,title,appid,destroy" "new,ack,state,unmap,destroy" \
        "new,ack,burst,destroy" "layer,unlayer,acklayers,new,ack" "new,ack,rerole,unmap,sub,unsub,destroy"; do
        client "p$i.log" RAYWM_CHAOS_SEED=$((seed * 100 + i)) RAYWM_CHAOS_OPS=$ops RAYWM_CHAOS_ONLY="$p" RAYWM_CHAOS_TAG=p$i \
            RAYWM_CHAOS_DELAY_MS=2 RAYWM_CHAOS_HOLD="$dir/release" "$BIN/raywm-test-chaos"
        echo "$! $p" >>"$dir/clients.txt"
        i=$((i + 1))
    done
    settle_all p 6
    sleep 0.5
    health settled
    audit_now settled "$(cat "$dir"/p*.log | grep -c '^chaos: mapped ')"
    : >"$dir/release"
    wait_pids 60 $(awk '{print $1}' "$dir/clients.txt")
    for t in 1 2; do wait_for "watch$t.log" 'perf: mode=watch' 120 || fail "taskbar $t did not finish"; done
    note "taskbar events: titles $(perf_value watch1 title), done $(perf_value watch1 done); $(trend)"
    stop "$expected"
    case_end
}

c_taskbar_flood() {
    case_begin taskbar-flood "$seed"
    printf 'raywm.load("dwindle")\nraywm.load("binds")\n' >"$dir/init.lua"
    start "$dir/init.lua" 1 || { case_end; return; }
    secs=$(level_pick 4 15 60)
    for t in 1 2; do client "watch$t.log" "$BIN/raywm-test-perf" watch $((secs + 2)); done
    wait_for watch1.log 'perf: ready' 10 || fail "taskbar did not start"
    client spin1.log "$BIN/raywm-test-perf" spin "$secs" fullscreen; p1=$!
    client spin2.log "$BIN/raywm-test-perf" spin "$secs"; p2=$!
    client spin3.log "$BIN/raywm-test-perf" spin "$secs" translucent; p3=$!
    wait_pids $((secs + 30)) $p1 $p2 $p3
    for t in 1 2; do wait_for "watch$t.log" 'perf: mode=watch' 30 || fail "taskbar $t did not finish"; done
    commits=$(( $(perf_value spin1 commits) + $(perf_value spin2 commits) + $(perf_value spin3 commits) ))
    for t in 1 2; do
        ti=$(perf_value "watch$t" title); dn=$(perf_value "watch$t" done)
        # Three windows: a map each plus a few state changes (fullscreen,
        # tiling). Never anything proportional to the commit count.
        [ "${ti:-999}" -le 30 ] || fail "taskbar $t got $ti title events for $commits commits"
        [ "${dn:-999}" -le 90 ] || fail "taskbar $t got $dn done events for $commits commits"
    done
    note "$commits commits in $secs s by 3 uncapped clients; taskbar: titles $(perf_value watch1 title), done $(perf_value watch1 done); cpu $(cpu_s) s"
    [ "$commits" -gt 300 ] || fail "uncapped clients made only $commits commits"
    stop
    case_end
}

c_invalid_storm() {
    case_begin invalid-storm "$seed"
    start "$stress_root/config/lifecycle.lua" 1 || { case_end; return; }
    : >"$dir/stop"
    n=$(level_pick 20 60 120)
    for i in 1 2 3; do
        client "v$i.log" RAYWM_CHAOS_SEED=$((seed * 1000 + i)) RAYWM_CHAOS_OPS=$ops RAYWM_CHAOS_TAG=v$i RAYWM_CHAOS_DELAY_MS=3 \
            RAYWM_CHAOS_HOLD="$dir/release" "$BIN/raywm-test-chaos"
        echo $! >>"$dir/valid.pids"
    done
    i=0; bad=
    while [ $i -lt "$n" ]; do
        client "x$i.log" RAYWM_CHAOS_SEED=$((seed * 1000 + 100 + i)) RAYWM_CHAOS_OPS=$((20 + i % 50)) RAYWM_CHAOS_INVALID=1 "$BIN/raywm-test-chaos"
        bad="$bad $!"; i=$((i + 1))
    done
    wait_pids 120 $bad
    ok=0; i=0
    while [ $i -lt "$n" ]; do grep -q 'disconnected as expected' "$dir/x$i.log" && ok=$((ok + 1)); grep -q 'NOT disconnected' "$dir/x$i.log" && fail "x$i: violation accepted"; i=$((i + 1)); done
    [ "$ok" -eq "$n" ] || fail "only $ok of $n violating clients were disconnected"
    for i in 1 2 3; do wait_for "v$i.log" 'settled\|FAIL' 120; grep -q FAIL "$dir/v$i.log" && fail "valid client v$i: $(grep -m1 FAIL "$dir/v$i.log")"; done
    audit_now valid "$(cat "$dir"/v*.log | grep -c '^chaos: mapped ')"
    : >"$dir/release"; wait_pids 30 $(cat "$dir/valid.pids")
    note "$n violators disconnected, 3 valid clients unaffected; $(trend)"
    stop "$expected"
    case_end
}

c_kill_pending() {
    case_begin kill-pending "$seed"
    start "$stress_root/config/lifecycle.lua" 1 || { case_end; return; }
    rounds=$(level_pick 15 80 300)
    r=0
    while [ $r -lt "$rounds" ]; do
        client "k$r.log" RAYWM_CHAOS_SEED=$((seed * 1000 + r)) RAYWM_CHAOS_OPS=100000 RAYWM_CHAOS_DELAY_MS=1 "$BIN/raywm-test-chaos"
        kp=$!
        # Killed after a seeded delay of 50..800 ms, wherever it is.
        sleep "$(python3 -c "import random; r = random.Random($seed * 1000 + $r); print(r.randrange(50, 800) / 1000)")"
        kill -9 "$kp" 2>/dev/null || true; wait "$kp" 2>/dev/null || true
        r=$((r + 1))
        [ $((r % 5)) -eq 0 ] && health "after $r kills"
    done
    : >"$dir/stop"; sleep 0.5
    audit_now after 0
    note "$rounds clients SIGKILLed mid-sequence; $(trend)"
    stop "$expected"
    case_end
}

c_outputs() {
    case_begin outputs "$seed"
    COMPOSITOR_ENV="RAYWM_CHAOS_PERIOD_MS=${PR_CHAOS_PERIOD:-5} ${PR_ENV:-}" start "$stress_root/config/${PR_CONFIG:-lifecycle}.lua" 2 || { case_end; return; }
    i=0
    while [ $i -lt "${PR_CLIENTS:-4}" ]; do
        client "o$i.log" RAYWM_CHAOS_SEED=$((seed * 100 + i)) RAYWM_CHAOS_OPS=$ops RAYWM_CHAOS_TAG=o$i RAYWM_CHAOS_DELAY_MS=4 \
            RAYWM_CHAOS_HOLD="$dir/release" "$BIN/raywm-test-chaos"
        echo $! >>"$dir/pids"; i=$((i + 1))
    done
    cycles=$(level_pick 6 30 100); c=0; next=3
    while [ $c -lt "$cycles" ]; do
        # Unplug the output that was plugged in last (HEADLESS-2 first).
        name=$([ $c -eq 0 ] && echo HEADLESS-2 || echo "HEADLESS-$((next - 1))")
        echo "$name" >"$dir/raywm-test-unplug"; kill -USR2 "$rpid"
        sleep 0.2
        kill -USR1 "$rpid"; next=$((next + 1))
        sleep 0.3
        c=$((c + 1))
        health "hotplug $c"
    done
    settle_all o "${PR_CLIENTS:-4}"
    : >"$dir/stop"; sleep 0.8
    audit_now settled "$(cat "$dir"/o*.log | grep -c '^chaos: mapped ')"
    n_out=$(ipc outputs 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
    [ "$n_out" -eq 2 ] || fail "$n_out outputs after $cycles unplug/plug cycles, expected 2"
    : >"$dir/release"; wait_pids 30 $(cat "$dir/pids")
    note "$cycles unplug/plug cycles under load; $(trend)"
    stop "$expected"
    case_end
}

c_xwayland() {
    command -v Xwayland >/dev/null || { echo "     xwayland: Xwayland not installed, NOT RUN"; return; }
    case_begin xwayland "$seed"
    RAYWM_XWAYLAND=1 start "$stress_root/config/lifecycle.lua" 1 || { case_end; return; }
    : >"$dir/stop"
    for i in 0 1; do
        client "w$i.log" RAYWM_CHAOS_SEED=$((seed * 100 + i)) RAYWM_CHAOS_OPS=$ops RAYWM_CHAOS_TAG=w$i RAYWM_CHAOS_DELAY_MS=4 \
            RAYWM_CHAOS_HOLD="$dir/release" "$BIN/raywm-test-chaos"
        echo $! >>"$dir/pids"
    done
    wait_for raywm.log 'lazy Xwayland display' 10 || { fail "no Xwayland display"; stop; case_end; return; }
    xd=$(sed -n 's/.*lazy Xwayland display \(:[0-9]*\).*/\1/p' "$dir/raywm.log" | tail -1)
    rounds=$(level_pick 8 40 120); r=0; xkills=0
    while [ $r -lt "$rounds" ]; do
        env -i PATH="$PATH" DISPLAY="$xd" XDG_RUNTIME_DIR="$dir" RAYWM_TEST_X11_FULLSCREEN=$((r % 2)) \
            "$BIN/raywm-test-x11" "$dir/x11cmd-$r" >"$dir/x$r.log" 2>&1 &
        xp=$!
        wait_for "x$r.log" 'x11: mapped\|x11: geometry' 15 || note "X11 client $r did not map (Xwayland restarting?)"
        for cmd in "fullscreen 1" "fullscreen 0" "maximize 1" "fullscreen 1"; do echo "$cmd" >"$dir/x11cmd-$r"; sleep 0.05; done
        if [ $((r % 3)) -eq 0 ]; then kill -9 $xp 2>/dev/null; else echo quit >"$dir/x11cmd-$r"; fi
        sleep 0.2; kill -9 $xp 2>/dev/null || true; wait $xp 2>/dev/null || true
        # Every fourth round the X server itself dies.
        if [ $((r % 4)) -eq 3 ]; then pkill -9 -f "Xwayland $xd" 2>/dev/null && xkills=$((xkills + 1)); sleep 0.5; fi
        r=$((r + 1))
        health "x11 round $r"
    done
    settle_all w 2
    sleep 0.5
    audit_now settled "$(cat "$dir"/w*.log | grep -c '^chaos: mapped ')"
    : >"$dir/release"; wait_pids 30 $(cat "$dir/pids")
    note "$rounds X11 clients (fullscreen toggles, $((rounds / 3 + 1)) SIGKILLed), X server killed $xkills times; $(grep -c 'Xwayland ready' "$dir/raywm.log") X server starts; $(trend)"
    stop "$expected|\[ERROR\] \[xwayland|DeleteProperty|Failed to get window property|BadWindow"
    case_end
}

for c in profiles taskbar-flood invalid-storm kill-pending outputs xwayland; do
    want_case "$c" && "c_$(echo "$c" | tr - _)"
done
summary

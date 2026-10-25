#!/bin/sh
# Window lifecycle torture: several raywm-test-chaos clients (random
# protocol operations), the chaos plugin (random window management from the
# compositor side) and random real input (focus/swap/resize/float/
# fullscreen/workspace keys, clicks, Super+drags) all at once, on two
# outputs. After each round everything settles and is audited:
#   * the compositor is alive and answers IPC in time, no crash, no
#     unexpected error lines, clean exit (and no leaks with -Dleak-check);
#   * every window a client holds is known to the compositor and nothing
#     else: IPC titles == the clients' settled windows;
#   * focus, tiling (no overlap, inside the usable area), one workspace per
#     output (tests/stress/plugins/audit.lua);
#   * after all clients exit: no windows, no focus, file descriptors back to
#     the level before the round.
# Clients in a round get seeds SEED*100+i; one of them may end with a
# protocol violation (it must be the only one disconnected) or crash.
. "$(dirname "$0")/../lib.sh"
repro_extra="--iterations 1" # a round's seed is the run's seed
rounds=${STRESS_ITER:-$(level_pick 2 12 40)}
clients=${LC_CLIENTS:-$(level_pick 4 6 8)}
ops=$(level_pick 300 1500 3000)
input_ops=${LC_INPUT_OPS:-$(level_pick 150 800 1500)}
expected='\[audit\]|\[chaos\]'
r=0
want_case mixed-round || rounds=0
while [ $r -lt "$rounds" ]; do
    seed=$((STRESS_SEED + r))
    case_begin "mixed-round" "$seed"
    COMPOSITOR_ENV="RAYWM_CHAOS_PERIOD_MS=${LC_CHAOS_PERIOD:-$(level_pick 6 4 3)} RAYWM_CHAOS_RELOAD=${LC_CHAOS_RELOAD:-$(level_pick 2 3 3)} ${LC_COMPOSITOR_ENV:-}" start "$stress_root/config/lifecycle.lua" 2 || { case_end; r=$((r + 1)); continue; }
    # Warm-up: the first keyboard and the first client create lazily kept
    # state (the keymap's two shm files, an activation-token random source);
    # the baseline is taken after it, so only growth counts.
    client warmup.log RAYWM_CHAOS_SEED=$seed RAYWM_CHAOS_OPS=40 "$BIN/raywm-test-chaos"
    wait_pids 30 $!
    drive key super down key j down key j up key super up || true
    sleep 0.3
    fd0=$(fds_now); fd_list >"$dir/fds-before.txt"
    health start; phase start
    pids=
    i=0
    while [ $i -lt "$clients" ]; do
        cs=$((seed * 100 + i))
        extra=
        # Client 0 of odd rounds ends with a protocol violation, client 1 of
        # rounds divisible by 3 crashes after settling.
        [ $i -eq 0 ] && [ $((seed % 2)) -eq 1 ] && extra="RAYWM_CHAOS_INVALID=1"
        [ $i -eq 1 ] && [ $((seed % 3)) -eq 0 ] && extra="RAYWM_CHAOS_CRASH=1"
        # shellcheck disable=SC2086
        client "chaos-$i.log" RAYWM_CHAOS_SEED=$cs RAYWM_CHAOS_OPS=$ops RAYWM_CHAOS_MAX=5 RAYWM_CHAOS_TAG="c$i" RAYWM_CHAOS_DELAY_MS=$(level_pick 4 6 6) \
            RAYWM_CHAOS_HOLD="$dir/release" ${CHAOS_ENV:-} $extra "$BIN/raywm-test-chaos"
        pids="$pids $!"; echo "$! $i $cs $extra" >>"$dir/clients.txt"
        i=$((i + 1))
    done
    # Random input until the clients settled.
    python3 "$stress_root/gen.py" input "$seed" "$input_ops" 2560 >"$dir/input.args"
    # shellcheck disable=SC2046
    phase input; drive $(cat "$dir/input.args") || fail "input driver failed"; phase input-done
    health "after input"
    # Every client either settles (and holds) or ends as designed.
    for line in $(awk '{print $1 ":" $2}' "$dir/clients.txt"); do
        p=${line%%:*}; n=${line#*:}
        w=0
        until grep -q 'settled\|disconnected as expected\|FAIL\|NOT disconnected' "$dir/chaos-$n.log" 2>/dev/null; do
            w=$((w + 1)); if [ $w -gt 1200 ]; then fail "client $n did not settle in 60 s"; break; fi
            kill -0 "$p" 2>/dev/null || break; sleep 0.05
        done
        grep -q 'FAIL' "$dir/chaos-$n.log" && fail "client $n: $(grep -m1 FAIL "$dir/chaos-$n.log")"
        grep -q 'NOT disconnected' "$dir/chaos-$n.log" && fail "client $n: protocol violation was accepted"
    done
    : >"$dir/stop"; phase stop
    wait_for chaos-stopped . 10 2>/dev/null || [ -e "$dir/chaos-stopped" ] || fail "chaos plugin did not stop"
    sleep 0.5
    health settled
    # Windows the clients hold (crashed/violating clients hold none).
    held=$(cat "$dir"/chaos-*.log | grep -c '^chaos: mapped ' || true)
    crashed=$(grep -l 'crash exit\|disconnected as expected' "$dir"/chaos-*.log 2>/dev/null | wc -l)
    if [ "$crashed" -gt 0 ]; then
        # Their windows go away asynchronously.
        sleep 0.5
        held=$(for f in "$dir"/chaos-*.log; do grep -q 'crash exit\|disconnected' "$f" || grep '^chaos: mapped ' "$f"; done | wc -l)
    fi
    echo "$held" >"$dir/expect-views"
    : >"$dir/audit-request"
    wait_for audit.txt 'audit done' 10 || fail "audit did not run"
    grep VIOLATION "$dir/audit.txt" | head -5 | while read -r v; do echo "     $v"; done
    grep -q VIOLATION "$dir/audit.txt" && fail "audit: $(grep -c VIOLATION "$dir/audit.txt") violation(s), first: $(grep -m1 VIOLATION "$dir/audit.txt")"
    # IPC titles == the clients' windows.
    ipc windows >"$dir/windows.json" 2>>"$dir/ipc.err" || fail "IPC windows failed"
    python3 -c 'import json,sys; [print(w["title"]) for w in json.load(open(sys.argv[1]))]' "$dir/windows.json" 2>/dev/null | sort >"$dir/titles.compositor" || true
    for f in "$dir"/chaos-*.log; do grep -q 'crash exit\|disconnected' "$f" || sed -n 's/^chaos: mapped //p' "$f"; done | sort >"$dir/titles.clients"
    if ! cmp -s "$dir/titles.compositor" "$dir/titles.clients"; then
        fail "compositor windows differ from the clients' (stale or lost windows): $(diff "$dir/titles.clients" "$dir/titles.compositor" | grep '^[<>]' | head -3 | tr '\n' ' ')"
    fi
    # Release: clients tear down (one may crash instead).
    : >"$dir/release"; phase release
    # shellcheck disable=SC2086
    wait_pids 30 $pids
    for f in "$dir"/chaos-*.log; do
        grep -q 'done\|crash exit\|disconnected as expected' "$f" || fail "$(basename "$f"): no clean end ($(tail -1 "$f"))"
    done
    sleep 0.5
    echo 0 >"$dir/expect-views"
    : >"$dir/audit-request"
    wait_for audit.txt 'audit done 2' 10 || fail "second audit did not run"
    grep -q VIOLATION "$dir/audit.txt" && fail "after all clients left: $(grep -m1 VIOLATION "$dir/audit.txt")"
    grep -q 'focused=true' "$dir/audit.txt" && fail "focus left on a window after all clients left"
    phase fd-check; fd1=$(fds_now); fd_list >"$dir/fds-after.txt"
    check_fds "$dir/fds-before.txt" "$dir/fds-after.txt" 2
    health end
    note "$(trend); fds $fd0->$fd1; chaos actions $(cat "$dir/chaos-stopped" 2>/dev/null || echo ?); loads $(cat "$dir/chaos-loads" 2>/dev/null); cpu $(cpu_s) s"
    stop "$expected"
    case_end
    r=$((r + 1))
done
# Hundreds of short-lived clients one after another (each maps windows,
# popups and subsurfaces, then disconnects, a third of them without
# cleaning up): nothing may accumulate.
if want_case sequential-clients; then
    n=$(level_pick 150 600 2000)
    case_begin sequential-clients "$STRESS_SEED"
    start "$stress_root/config/lifecycle.lua" 1 || { case_end; summary; }
    : >"$dir/stop"
    client warm.log RAYWM_CHAOS_SEED=1 RAYWM_CHAOS_OPS=40 "$BIN/raywm-test-chaos"; wait_pids 30 $!
    sleep 0.3; fd_list >"$dir/fds-before.txt"; r0=$(rss_now)
    i=0
    while [ $i -lt "$n" ]; do
        extra=; [ $((i % 3)) -eq 0 ] && extra="RAYWM_CHAOS_CRASH=1"
        # shellcheck disable=SC2086
        client "s.log" RAYWM_CHAOS_SEED=$((STRESS_SEED * 10000 + i)) RAYWM_CHAOS_OPS=$((20 + i % 60)) $extra "$BIN/raywm-test-chaos"
        cp_=$!; wait_pids 30 $cp_
        grep -q 'chaos: done\|crash exit' "$dir/s.log" || { fail "client $i: $(tail -1 "$dir/s.log")"; cp "$dir/s.log" "$dir/failed-$i.log"; }
        i=$((i + 1))
        [ $((i % 100)) -eq 0 ] && { health "after $i clients"; printf '%s\t%s\t%s\n' "$i" "$(rss_now)" "$(fds_now)" >>"$dir/per100.tsv"; }
    done
    sleep 0.5
    echo 0 >"$dir/expect-views"; : >"$dir/audit-request"
    wait_for audit.txt 'audit done' 10 || fail "audit did not run"
    grep -q VIOLATION "$dir/audit.txt" && fail "after $n clients: $(grep -m1 VIOLATION "$dir/audit.txt")"
    fd_list >"$dir/fds-after.txt"; check_fds "$dir/fds-before.txt" "$dir/fds-after.txt" 1
    note "$n sequential clients ($((n / 3)) without cleanup): RSS $r0 -> $(rss_now) kB; per 100: $(awk '{printf "%s ", $2}' "$dir/per100.tsv" 2>/dev/null)"
    stop "$expected"
    case_end
fi
summary

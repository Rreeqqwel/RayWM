#!/bin/sh
# Long-running soak: one compositor (two outputs, the desktop plugins plus
# chaos and audit) for STRESS_DURATION seconds (run.sh --duration; e.g. 300
# smoke, 1800 extended, 7200 soak, longer by hand), in rounds that mix every
# subsystem at once: chaos clients, random input, IPC queries, raywm.conf
# rewrites with reloads, output unplug/plug, uncapped clients with a
# taskbar, and compositor-side chaos. After every round: alive, IPC answers
# in time, no stale windows (audit with 0 expected views, valid focus).
# Resources are sampled every SAMPLE_S (5) seconds; at the end the RSS
# trend after the first fifth of the run (warm-up) must be flat:
#   slope <= 16 MiB/hour, or the total rise <= 8 MiB,
# and the descriptor count must stay below 200 (bounded state only).
# A dead or unresponsive compositor fails at once (no infinite wait).
. "$(dirname "$0")/../lib.sh"
seed=$STRESS_SEED
duration=${STRESS_DURATION:-300}
SAMPLE_S=${SAMPLE_S:-5}
case_begin "soak-${duration}s" "$seed"
COMPOSITOR_ENV="RAYWM_CHAOS_PERIOD_MS=10 RAYWM_CHAOS_RELOAD=1" SESSION_TIMEOUT=$((duration + 900)) \
    start "$stress_root/config/lifecycle.lua" 2 || { case_end; summary; }
t_end=$(( $(date +%s) + duration ))
r=0; next_out=3; rounds_ok=0
while [ "$(date +%s)" -lt "$t_end" ]; do
    rs=$((seed * 10000 + r))
    pids=
    for i in 0 1 2; do
        client "c$i.log" RAYWM_CHAOS_SEED=$((rs * 10 + i)) RAYWM_CHAOS_OPS=1500 RAYWM_CHAOS_DELAY_MS=4 RAYWM_CHAOS_TAG="r${r}c$i" "$BIN/raywm-test-chaos"
        pids="$pids $!"
    done
    python3 "$stress_root/gen.py" input "$rs" 300 2560 >"$dir/input.args"
    # shellcheck disable=SC2046
    drive $(cat "$dir/input.args") || fail "round $r: input driver failed"
    ipc windows >/dev/null 2>&1 || true; ipc workspaces >/dev/null 2>&1 || true; ipc perf >/dev/null 2>&1 || true
    if [ $((r % 3)) -eq 2 ]; then
        # A random valid raywm.conf (or a broken one now and then), then reload.
        python3 "$stress_root/gen.py" conf "$rs" "$dir/confs" 1 >/dev/null
        cp "$dir/confs/fuzz-0000.conf" "$dir/config/raywm/raywm.conf"
        drive key ctrl down key alt down key r down key r up key alt up key ctrl up || true
    fi
    # At most 12 hotplug cycles: each new headless output has a new name
    # (HEADLESS-3, -4, ...) and workspaces.lua keeps the workspaces of
    # every output name it has seen, so endless hotplug grows that state
    # (bounded by the connectors of real hardware; see the report).
    if [ $((r % 5)) -eq 4 ] && [ "$next_out" -lt 15 ]; then
        echo "HEADLESS-$([ $next_out -eq 3 ] && echo 2 || echo $((next_out - 1)))" >"$dir/raywm-test-unplug"; kill -USR2 "$rpid" 2>/dev/null || true
        sleep 0.3; kill -USR1 "$rpid" 2>/dev/null || true; next_out=$((next_out + 1))
    fi
    if [ $((r % 4)) -eq 3 ]; then
        client watch.log "$BIN/raywm-test-perf" watch 3; wp=$!
        client spin.log "$BIN/raywm-test-perf" spin 2 fullscreen; sp=$!
        wait_pids 20 $wp $sp
    fi
    # shellcheck disable=SC2086
    wait_pids 120 $pids
    for i in 0 1 2; do grep -q 'chaos: done' "$dir/c$i.log" || { fail "round $r client $i: $(tail -1 "$dir/c$i.log")"; cp "$dir/c$i.log" "$dir/failed-r$r-c$i.log"; }; done
    sleep 0.5
    if ! health "round $r"; then break; fi
    echo 0 >"$dir/expect-views"; rm -f "$dir/audit.txt"; : >"$dir/audit-request"
    if wait_for audit.txt 'audit done' 10; then
        grep -q VIOLATION "$dir/audit.txt" && { fail "round $r: $(grep -m1 VIOLATION "$dir/audit.txt")"; cp "$dir/audit.txt" "$dir/audit-r$r.txt"; }
    else
        fail "round $r: audit did not run"
    fi
    # Quiescent sample: every client gone, nothing on screen.
    printf '%s\t%s\t%s\n' "$(now_ms)" "$(rss_now)" "$(fds_now)" >>"$dir/quiet.tsv"
    rounds_ok=$((rounds_ok + 1)); r=$((r + 1))
    # Keep the logs bounded on long runs.
    [ $((r % 50)) -eq 0 ] && : >"$dir/driver.log"
done
health end
# The trend uses the quiescent samples (taken after each round, with no
# window left): transient buffers of a busy moment do not count there.
printf 't_ms\trss_kb\tfds\n' | cat - "$dir/quiet.tsv" >"$dir/quiet-h.tsv" 2>/dev/null || true
python3 - "$dir/quiet-h.tsv" "$duration" "$dir/samples.tsv" >"$dir/trend.txt" <<'PY'
import sys
rows = [l.split("\t") for l in open(sys.argv[1]).read().splitlines()[1:]]
rows = [(int(t), int(r), int(f)) for t, r, f, *_ in rows if r != "0"]
busy = [l.split("\t") for l in open(sys.argv[3]).read().splitlines()[1:]]
busy_peak = max((int(r) for _, r, *_ in busy if r.isdigit()), default=0) / 1024
if len(rows) < 5:
    print("quiet_samples %d too few for a trend" % len(rows)); sys.exit(0)
t0 = rows[0][0]
warm = rows[len(rows) // 5:]
xs = [(t - t0) / 3600000 for t, _, _ in warm]; ys = [r / 1024 for _, r, _ in warm]
n = len(xs); mx = sum(xs) / n; my = sum(ys) / n
sxx = sum((x - mx) ** 2 for x in xs) or 1e-9
slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
rise = ys[-1] - ys[0]
print("quiet_samples %d warm_from_mib %.1f end_mib %.1f quiet_peak_mib %.1f busy_peak_mib %.1f rise_mib %.1f slope_mib_per_h %.2f max_fds %d end_fds %d" % (
    len(rows), ys[0], ys[-1], max(ys), busy_peak, rise, slope, max(f for _, _, f in rows), rows[-1][2]))
PY
read_trend() { sed -n "s/.* $1 \([-0-9.]*\).*/\1/p" "$dir/trend.txt"; }
slope=$(read_trend slope_mib_per_h); rise=$(read_trend rise_mib); maxfd=$(read_trend max_fds)
if [ -n "$slope" ]; then
    awk -v s="$slope" -v r="$rise" 'BEGIN {exit !(s > 16 && r > 8)}' && fail "RSS keeps growing: $slope MiB/h after warm-up (rise $rise MiB)"
    [ "${maxfd:-0}" -lt 200 ] || fail "$maxfd file descriptors open at the peak"
fi
note "$rounds_ok rounds in $duration s; $(cat "$dir/trend.txt"); reloads $(grep -c reloading "$dir/raywm.log"); cpu $(cpu_s) s"
stop '\[chaos\]|\[audit\]|error\(conf\)'
case_end
summary

#!/bin/sh
# Performance torture, headless (pixman): numbers, not GPU frame rates.
# Every scenario runs on this build and, with BASELINE_BIN (an older test
# build, e.g. v0.2.2-beta), on the baseline too: a warm-up, then REPEATS
# (3) samples, median reported. Results: <case dir>/perf.json.
#   startup         time until the startup command runs, RSS after start
#   idle            compositor CPU over 5 s with windows open and nothing
#                   happening (must stay near zero)
#   commit-storm    uncapped clients (fullscreen and windowed): CPU, RSS,
#                   commits and presentation counters (raywm-test-perf)
#   ipc             latency of IPC queries: sequential, and 8 clients at once
#   reload          configuration reloads: time per reload, RSS afterwards
#   switching       workspace switches and fullscreen toggles with windows
#   churn           windows mapped/unmapped with the animations plugin
# Fails only on gross regressions against the baseline (more than 1.5x and
# above a noise floor) or on absolute limits (idle CPU); the numbers are
# the point. GPU, DRM/KMS, VRR and real frame rates are NOT measured here.
. "$(dirname "$0")/../lib.sh"
seed=$STRESS_SEED
repeats=$(level_pick 3 5 9)
builds="current"; [ -n "${BASELINE_BIN:-}" ] && builds="current baseline"
cur_bin=$BIN

use_build() { if [ "$1" = baseline ]; then BIN=$BASELINE_BIN; else BIN=$cur_bin; fi; }
# Clients and the input driver always come from this build (the protocol
# is the same); only the compositor changes.
clients_bin=$cur_bin
median() { sort -n | awk '{a[NR] = $1} END {if (NR == 0) print 0; else print a[int((NR + 1) / 2)]}'; }
record() { # CASE BUILD METRIC VALUE
    printf '{"case": "%s", "build": "%s", "metric": "%s", "value": %s}\n' "$1" "$2" "$3" "$4" >>"$STRESS_OUT/perf.jsonl"
}
# compare CASE METRIC FLOOR: fail if current > 1.5 x baseline and > FLOOR.
compare() {
    [ -n "${BASELINE_BIN:-}" ] || return 0
    python3 - "$STRESS_OUT/perf.jsonl" "$1" "$2" "$3" <<'PY' || fail "$2: regression against the baseline ($(tail -1 "$dir/compare.txt"))"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
case, metric, floor = sys.argv[2], sys.argv[3], float(sys.argv[4])
v = {r["build"]: r["value"] for r in rows if r["case"] == case and r["metric"] == metric}
c, b = v.get("current"), v.get("baseline")
line = "%s %s: current %s, baseline %s" % (case, metric, c, b)
open(sys.argv[1].replace("perf.jsonl", "compare.txt"), "a").write(line + "\n")
print(line)
sys.exit(1 if c is not None and b is not None and c > 1.5 * b and c > floor else 0)
PY
}
pclient() { log=$1; shift; env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" "$clients_bin/$@" >"$dir/$log" 2>&1; }
pclient_bg() { log=$1; shift; env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" "$clients_bin/$@" >"$dir/$log" 2>&1 & }
pdrive() { env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" RAYWM_TEST_EXTENT="1280x720" "$clients_bin/raywm-test-input" "$@" >>"$dir/driver.log" 2>&1; }
hold_windows() { # N
    k=0
    while [ $k -lt "$1" ]; do
        env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 \
            "$clients_bin/raywm-test-client" >"$dir/hold$k.log" 2>&1 &
        echo $! >>"$dir/holds"
        wait_for "hold$k.log" 'frame done' 10 || fail "window $k did not map"
        k=$((k + 1))
    done
}
release_windows() { [ -f "$dir/holds" ] && kill $(cat "$dir/holds") 2>/dev/null; rm -f "$dir/holds"; }

c_startup() {
    case_begin startup "$seed"
    for b in $builds; do
        use_build "$b"; t_list=; r_list=; i=0
        while [ $i -le "$repeats" ]; do
            t="$dir/$b-$i"; mkdir -p "$t/config/raywm/plugins"; chmod 700 "$t"
            cp "$root/config/plugins/"*.lua "$t/config/raywm/plugins/"; cp "$root/config/init.lua" "$t/config/raywm/"
            t0=$(now_ms)
            env -i PATH="$PATH" HOME="$t" XDG_RUNTIME_DIR="$t" XDG_CONFIG_HOME="$t/config" RAYWM_SYSTEM_CONF= RAYWM_XWAYLAND=0 \
                WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
                timeout 30 "$BIN/raywm" -s "echo up >'$t/up'" >"$t/log" 2>&1 &
            p=$!
            while [ ! -e "$t/up" ] && kill -0 $p 2>/dev/null; do sleep 0.002; done
            ms=$(($(now_ms) - t0))
            sleep 0.5
            c=$(pgrep -P $p -x raywm || true)
            rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$c/status" 2>/dev/null || echo 0)
            kill -TERM "${c:-$p}"; wait $p 2>/dev/null || true
            # Sample 0 is the warm-up (page cache, xkb compilation cache).
            [ $i -gt 0 ] && { t_list="$t_list $ms"; r_list="$r_list $rss"; }
            rm -rf "$t"; i=$((i + 1))
        done
        tm=$(echo $t_list | tr ' ' '\n' | median); rm_=$(echo $r_list | tr ' ' '\n' | median)
        record startup "$b" start_ms "$tm"; record startup "$b" rss_kb "$rm_"
        note "$b: start $tm ms (samples:$t_list), RSS $rm_ kB"
    done
    compare startup start_ms 150; compare startup rss_kb 40000
    BIN=$cur_bin; case_end
}

c_idle() {
    case_begin idle "$seed"
    for b in $builds; do
        use_build "$b"
        printf 'raywm.load("dwindle")\nraywm.load("binds")\nraywm.load("focus")\n' >"$dir/init.lua"
        start "$dir/init.lua" 1 || continue
        hold_windows 4; sleep 1
        c0=$(cpu_ticks); sleep 5; c1=$(cpu_ticks)
        ticks=$((c1 - c0)); hz=$(getconf CLK_TCK)
        pct=$(awk -v t=$ticks -v hz=$hz 'BEGIN {printf "%.2f", 100 * t / hz / 5}')
        record idle "$b" cpu_percent "$pct"; note "$b: idle CPU $pct % over 5 s with 4 windows"
        awk -v p="$pct" 'BEGIN {exit !(p > 2)}' && fail "$b: idle compositor uses $pct % CPU"
        release_windows; stop
    done
    BIN=$cur_bin; case_end
}

c_commit_storm() {
    case_begin commit-storm "$seed"
    secs=$(level_pick 4 10 30)
    for b in $builds; do
        use_build "$b"
        printf 'raywm.load("dwindle")\nraywm.load("binds")\n' >"$dir/init.lua"
        start "$dir/init.lua" 1 || continue
        pclient_bg watch.log raywm-test-perf watch $((secs + 2)); wp=$!
        sleep 0.3
        r0=$(rss_now); c0=$(cpu_ticks)
        pclient_bg s1.log raywm-test-perf spin "$secs" fullscreen; p1=$!
        pclient_bg s2.log raywm-test-perf spin "$secs"; p2=$!
        wait $p1 $p2 2>/dev/null; wait $wp 2>/dev/null
        c1=$(cpu_ticks); r1=$(rss_now)
        commits=$(( $(sed -n 's/.* commits=\([0-9]*\).*/\1/p' "$dir/s1.log") + $(sed -n 's/.* commits=\([0-9]*\).*/\1/p' "$dir/s2.log") ))
        presented=$(( $(sed -n 's/.* presented=\([0-9]*\).*/\1/p' "$dir/s1.log") + $(sed -n 's/.* presented=\([0-9]*\).*/\1/p' "$dir/s2.log") ))
        cpu=$(awk -v t=$((c1 - c0)) -v hz="$(getconf CLK_TCK)" 'BEGIN {printf "%.2f", t / hz}')
        per=$(awk -v c="$cpu" -v n="$commits" 'BEGIN {printf "%.2f", n ? 1e6 * c / n : 0}')
        titles=$(sed -n 's/.* title=\([0-9]*\).*/\1/p' "$dir/watch.log")
        record commit-storm "$b" commits "$commits"; record commit-storm "$b" presented "$presented"
        record commit-storm "$b" cpu_us_per_commit "$per"; record commit-storm "$b" rss_growth_kb "$((r1 - r0))"
        record commit-storm "$b" taskbar_titles "${titles:-0}"
        note "$b: $commits commits ($presented presented) in $secs s, compositor CPU $cpu s ($per µs/commit), RSS +$((r1 - r0)) kB, taskbar titles ${titles:-?}"
        stop
    done
    compare commit-storm cpu_us_per_commit 20; compare commit-storm rss_growth_kb 4096
    BIN=$cur_bin; case_end
}

c_ipc() {
    case_begin ipc "$seed"
    n=$(level_pick 2000 10000 30000)
    for b in $builds; do
        use_build "$b"
        printf 'raywm.load("dwindle")\nraywm.load("binds")\n' >"$dir/init.lua"
        start "$dir/init.lua" 1 || continue
        hold_windows 6
        python3 - "$dir/raywm-$(display_name).sock" "$n" >"$dir/ipc-$b.txt" <<'PY' || fail "$b: IPC benchmark failed: $(tail -2 "$dir/ipc-$b.txt")"
import json, socket, sys, threading, time
path, n = sys.argv[1], int(sys.argv[2])
def run(count, out):
    s = socket.socket(socket.AF_UNIX); s.connect(path); f = s.makefile("rb")
    lat = []
    for i in range(count):
        t = time.perf_counter()
        s.sendall(b'{"v":1,"id":%d,"method":"windows"}\n' % i)
        r = json.loads(f.readline())
        assert r.get("ok"), r
        lat.append((time.perf_counter() - t) * 1e6)
    s.close(); out.extend(lat)
seq = []; run(n, seq)
par = []; threads = [threading.Thread(target=run, args=(n // 8, par)) for _ in range(8)]
t0 = time.perf_counter(); [t.start() for t in threads]; [t.join() for t in threads]; wall = time.perf_counter() - t0
def pct(a, p): a = sorted(a); return a[min(len(a) - 1, int(len(a) * p))]
print("seq_p50_us %.0f seq_p99_us %.0f par_p50_us %.0f par_p99_us %.0f par_rps %.0f" % (pct(seq, .5), pct(seq, .99), pct(par, .5), pct(par, .99), len(par) / wall))
PY
        line=$(tail -1 "$dir/ipc-$b.txt")
        for m in seq_p50_us seq_p99_us par_p50_us par_p99_us par_rps; do record ipc "$b" "$m" "$(echo "$line" | sed -n "s/.*$m \([0-9]*\).*/\1/p")"; done
        note "$b: $line (6 windows, $n requests)"
        release_windows; stop
    done
    compare ipc seq_p50_us 500; compare ipc par_p99_us 5000
    BIN=$cur_bin; case_end
}

c_reload() {
    case_begin reload "$seed"
    n=$(level_pick 30 100 300)
    for b in $builds; do
        use_build "$b"
        start "$root/config/init.lua" 1 || continue
        hold_windows 3
        pdrive key ctrl down key alt down key r down key r up key alt up key ctrl up sleep 200
        r0=$(rss_now); t0=$(now_ms); i=0
        while [ $i -lt "$n" ]; do
            pdrive key ctrl down key alt down key r down key r up key alt up key ctrl up
            i=$((i + 1))
        done
        ms=$(($(now_ms) - t0)); r1=$(rss_now)
        per=$(awk -v m=$ms -v n=$n 'BEGIN {printf "%.1f", m / n}')
        record reload "$b" ms_per_reload "$per"; record reload "$b" rss_growth_kb "$((r1 - r0))"
        note "$b: $n reloads, $per ms each (driver round trips included), RSS +$((r1 - r0)) kB"
        release_windows; stop
    done
    compare reload ms_per_reload 50; compare reload rss_growth_kb 2048
    BIN=$cur_bin; case_end
}

c_switching() {
    case_begin switching "$seed"
    n=$(level_pick 100 400 1000)
    for b in $builds; do
        use_build "$b"
        printf 'raywm.load("workspaces")\nraywm.load("dwindle")\nraywm.load("binds")\nraywm.load("focus")\n' >"$dir/init.lua"
        start "$dir/init.lua" 1 || continue
        hold_windows 6
        args=; i=0; while [ $i -lt 20 ]; do args="$args key super down key $((i % 2 + 1)) down key $((i % 2 + 1)) up key super up"; i=$((i + 1)); done
        t0=$(now_ms); i=0; while [ $i -lt $((n / 20)) ]; do pdrive $args; i=$((i + 1)); done
        ws_ms=$(awk -v m=$(($(now_ms) - t0)) -v n=$n 'BEGIN {printf "%.2f", m / n}')
        pdrive key super down key 1 down key 1 up key super up
        args=; i=0; while [ $i -lt 20 ]; do args="$args key super down key f down key f up key super up"; i=$((i + 1)); done
        t0=$(now_ms); i=0; while [ $i -lt $((n / 20)) ]; do pdrive $args; i=$((i + 1)); done
        fs_ms=$(awk -v m=$(($(now_ms) - t0)) -v n=$n 'BEGIN {printf "%.2f", m / n}')
        record switching "$b" workspace_switch_ms "$ws_ms"; record switching "$b" fullscreen_toggle_ms "$fs_ms"
        note "$b: workspace switch $ws_ms ms, fullscreen toggle $fs_ms ms (input round trips included)"
        health switching
        release_windows; stop
    done
    compare switching workspace_switch_ms 10; compare switching fullscreen_toggle_ms 10
    BIN=$cur_bin; case_end
}

c_churn() {
    case_begin churn "$seed"
    for b in $builds; do
        use_build "$b"
        printf 'raywm.load("dwindle")\nraywm.load("binds")\nraywm.load("animations")\nraywm.load("focus-indicator")\n' >"$dir/init.lua"
        start "$dir/init.lua" 1 || continue
        env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" RAYWM_CHAOS_SEED=1 RAYWM_CHAOS_OPS=100 "$clients_bin/raywm-test-chaos" >/dev/null 2>&1
        r0=$(rss_now); c0=$(cpu_ticks); t0=$(now_ms)
        env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" RAYWM_CHAOS_SEED=$seed \
            RAYWM_CHAOS_OPS=$(level_pick 2000 8000 20000) RAYWM_CHAOS_ONLY=new,ack,destroy,ack "$clients_bin/raywm-test-chaos" >"$dir/churn-$b.log" 2>&1 || fail "$b: churn client failed"
        ms=$(($(now_ms) - t0)); c1=$(cpu_ticks); r1=$(rss_now)
        cpu=$(awk -v t=$((c1 - c0)) -v hz="$(getconf CLK_TCK)" 'BEGIN {printf "%.2f", t / hz}')
        record churn "$b" cpu_s "$cpu"; record churn "$b" wall_ms "$ms"; record churn "$b" rss_growth_kb "$((r1 - r0))"
        note "$b: map/unmap churn with animations: $ms ms, compositor CPU $cpu s, RSS +$((r1 - r0)) kB"
        stop
    done
    compare churn cpu_s 2; compare churn rss_growth_kb 4096
    BIN=$cur_bin; case_end
}

for c in startup idle commit-storm ipc reload switching churn; do
    want_case "$c" && "c_$(echo "$c" | tr - _)"
done
summary

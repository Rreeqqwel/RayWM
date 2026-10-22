#!/bin/sh
# Bounded stress tests in an isolated headless compositor (test build with
# virtual input):  zig build -Dtest-input -p zig-out/test-input
#   1. 100 window create/destroy cycles
#   2. 20 waves of 8 clients killed with SIGKILL
#   3. 40 Lua reloads (Ctrl+Alt+R) with a plugin failing on every map
#   4. 3 s of geometry changes every 2 ms (a plugin timer) on an acking client
#   5. clean shutdown (SIGTERM -> exit 0, no unexpected errors)
# Reports compositor RSS before and after; fails on growth above a coarse
# threshold (default 16 MiB) that only catches gross leaks.
#   usage: [RENDERER=...] [KEEP=1] [RSS_LIMIT_KB=...] tests/stress.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-input" ] || { echo "stress: missing $bin/raywm-test-input (build with -Dtest-input)"; exit 2; }
limit=${RSS_LIMIT_KB:-16384}
failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

tmp=$(mktemp -d); chmod 700 "$tmp"
trap 'kill "$pid" 2>/dev/null || true; [ -n "${KEEP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config/raywm/plugins"
cp "$root/config/plugins/"*.lua "$root/tests/stress/plugins/"*.lua "$tmp/config/raywm/plugins/"
cp "$root/tests/stress/init.lua" "$tmp/config/raywm/init.lua"
client="$bin/raywm-test-client"

env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER="${RENDERER:-pixman}" WLR_LIBINPUT_NO_DEVICES=1 \
    timeout 300 "$bin/raywm" -s "echo \$WAYLAND_DISPLAY >'$tmp/display'" >"$tmp/raywm.log" 2>&1 &
pid=$!
i=0; while [ ! -s "$tmp/display" ]; do i=$((i + 1)); [ $i -gt 100 ] && { fail "compositor did not start"; exit 1; }; sleep 0.1; done

cenv() { env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" "$@"; }
# Background client whose $! is the client itself (env execs it); a
# backgrounded shell function would give the pid of a subshell instead.
cbg() { log=$1; shift; env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" "$@" >"$log" 2>&1 & }
# $pid is the `timeout` wrapper; measure the compositor itself (its child).
rss() { awk '/^VmRSS:/ {print $2}' "/proc/$(cat "/proc/$pid/task/$pid/children" | awk '{print $1}')/status"; }
alive() { kill -0 "$pid" 2>/dev/null || { fail "compositor died ($1)"; cat "$tmp/raywm.log" | tail -20; exit 1; }; }

# Warm-up so allocator pools exist before the baseline.
cenv RAYWM_TEST_ROUNDS=5 RAYWM_TEST_RESIZE=1 "$client" >"$tmp/warm.log" 2>&1 || fail "warm-up client failed"
rss0=$(rss)

# 1. Repeated window creation and destruction (with dwindle re-tiling).
start=$(date +%s)
cenv RAYWM_TEST_ROUNDS=100 RAYWM_TEST_RESIZE=1 "$client" >"$tmp/cycles.log" 2>&1 || fail "100-round client failed"
[ "$(grep -c 'resized' "$tmp/cycles.log")" -eq 100 ] || fail "not all 100 windows were tiled"
echo "1. 100 create/destroy cycles: $(($(date +%s) - start)) s"; alive cycles; echo "   RSS $(rss) KiB"

# 2. Clients that exit unexpectedly.
kill_rss=
for wave in $(seq 1 20); do
    pids=
    for n in 1 2 3 4 5 6 7 8; do
        cbg "$tmp/kill-$wave-$n.log" RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 "$client"
        pids="$pids $!"
    done
    for n in 1 2 3 4 5 6 7 8; do
        j=0; until grep -q 'frame done' "$tmp/kill-$wave-$n.log" 2>/dev/null; do j=$((j + 1)); [ $j -gt 100 ] && break; sleep 0.05; done
    done
    kill -9 $pids 2>/dev/null || true
    wait $pids 2>/dev/null || true
    for p in $pids; do ! kill -0 "$p" 2>/dev/null || fail "client $p survived SIGKILL"; done
    [ $((wave % 5)) -eq 0 ] && kill_rss="$kill_rss $(rss)"
done
echo "2. 20 waves x 8 clients killed with SIGKILL"; alive kills
echo "   RSS after waves 5/10/15/20:$kill_rss KiB"

# 3. Repeated reloads; crashy fails on each map and is loaded again.
for r in $(seq 1 40); do
    [ "$r" -eq 21 ] && rss_reload20=$(rss)
    cenv "$bin/raywm-test-input" key ctrl down key alt down key r down key r up key alt up key ctrl up >>"$tmp/driver.log" 2>&1 || fail "driver (reload $r)"
    cenv RAYWM_TEST_ROUNDS=1 "$client" >>"$tmp/reload-clients.log" 2>&1 || fail "client after reload $r"
done
reloads=$(grep -c "reloading" "$tmp/raywm.log" || true)
crashes=$(grep -c "crashy: expected failure" "$tmp/raywm.log" || true)
[ "$reloads" -eq 40 ] || fail "expected 40 reloads, saw $reloads"
[ "$crashes" -ge 40 ] || fail "crashy should fail after every reload ($crashes)"
echo "3. 40 reloads ($reloads seen), crashy failed $crashes times"; alive reloads
echo "   RSS after reload 20: ${rss_reload20} KiB, after reload 40: $(rss) KiB"

# 4. High-frequency geometry changes on a live, acking client.
cbg "$tmp/jitter.log" RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 "$client"
jpid=$!
j=0; until grep -q 'frame done' "$tmp/jitter.log" 2>/dev/null; do j=$((j + 1)); [ $j -gt 100 ] && break; sleep 0.05; done
cenv "$bin/raywm-test-input" key super down key f12 down key f12 up key super up sleep 3500 >>"$tmp/driver.log" 2>&1 || fail "driver (jitter)"
acks=$(grep -c "hold resized" "$tmp/jitter.log" || true)
[ "$acks" -ge 100 ] || fail "jitter: only $acks resizes acked"
kill $jpid 2>/dev/null || true; wait $jpid 2>/dev/null || true
echo "4. geometry storm: client acked $acks resizes in 3 s"; alive jitter; echo "   RSS $(rss) KiB"

rss1=$(rss)
echo "RSS: baseline ${rss0} KiB, after ${rss1} KiB, delta $((rss1 - rss0)) KiB (limit ${limit} KiB)"
[ $((rss1 - rss0)) -le "$limit" ] || fail "RSS grew by more than ${limit} KiB"

# 5. Clean shutdown.
kill -TERM "$pid"; status=0; wait "$pid" || status=$?; pid=
[ "$status" -eq 0 ] || fail "raywm exited with $status"
# Only the deliberate crashy failures may appear as errors.
if grep -E "panic|\[ERROR\]|error\(" "$tmp/raywm.log" | grep -v "crashy: expected failure" | grep -v "^stack traceback\|^\s" | grep -q .; then
    fail "unexpected errors in compositor log:"; grep -E "panic|\[ERROR\]|error\(" "$tmp/raywm.log" | grep -v crashy | head
fi
echo "5. clean shutdown: exit $status"

[ "$failures" -eq 0 ] && echo "stress: OK" || { echo "stress: $failures failure(s)"; exit 1; }

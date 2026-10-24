#!/bin/sh
# RayWM torture suite runner (docs/TORTURE.md).
#
#   tests/stress/run.sh [options]
#     --level fast|stress|soak  amount of work per case (default fast)
#     --category LIST           comma-separated: lifecycle,lua,config,protocol,
#                               update,perf,recovery,soak (default: all but soak;
#                               --level soak: soak)
#     --case SUBSTRING          only cases whose name contains it
#     --seed N                  master seed (default: random, always printed)
#     --iterations N            rounds/files/mutations per case (category default)
#     --duration SECONDS        soak duration (default 7200)
#     --timeout SECONDS         per-category wall-clock limit (default by level)
#     --rss-cap KB              fail a case whose compositor exceeds it (524288)
#     --out DIR                 results and logs (default stress-results/<date>-<seed>)
#     --bin DIR                 test build: zig build -Dtest-input [-Dleak-check] -p DIR
#                               (default zig-out/test-input/bin)
#     --baseline-bin DIR        perf: an older test build to compare against
#
# Writes DIR/results.jsonl (one JSON object per case: category, case, seed,
# status, duration, peak RSS/FDs, notes, log directory, reproduction command),
# DIR/summary.txt, and keeps every log. Exit status: 0 all passed, 1 a case
# failed, 2 usage or environment problem. Never touches the user's session:
# every compositor is headless with a private XDG_RUNTIME_DIR.
#
# Also: zig build stress -Dtest-input -p zig-out/test-input -- --level fast
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
level=fast categories= case_filter= seed= iterations= duration=7200 cat_timeout= rss_cap=524288 out= bin= baseline=
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --level) level=$2; shift ;;
        --category) categories=$(echo "$2" | tr ',' ' '); shift ;;
        --case) case_filter=$2; shift ;;
        --seed) seed=$2; shift ;;
        --iterations) iterations=$2; shift ;;
        --duration) duration=$2; shift ;;
        --timeout) cat_timeout=$2; shift ;;
        --rss-cap) rss_cap=$2; shift ;;
        --out) out=$2; shift ;;
        --bin) bin=$2; shift ;;
        --baseline-bin) baseline=$2; shift ;;
        -h|--help) usage ;;
        *) echo "run.sh: unknown option $1"; usage ;;
    esac
    shift
done
case "$level" in fast|stress|soak) ;; *) echo "run.sh: --level fast|stress|soak"; exit 2 ;; esac
[ -n "$seed" ] || seed=$(od -An -N3 -tu4 /dev/urandom | tr -d ' ')
[ -n "$categories" ] || categories=$([ "$level" = soak ] && echo soak || echo "config update lua lifecycle protocol recovery perf")
bin=$(cd "${bin:-$root/zig-out/test-input/bin}" 2>/dev/null && pwd) || { echo "run.sh: no test build; run: zig build -Dtest-input -p zig-out/test-input"; exit 2; }
for t in raywm raywm-test-input raywm-test-client raywm-test-chaos raywm-update; do
    [ -x "$bin/$t" ] || { echo "run.sh: $bin/$t missing (build with -Dtest-input)"; exit 2; }
done
out=${out:-$root/stress-results/$(date +%Y%m%d-%H%M%S)-$seed}
mkdir -p "$out"; out=$(cd "$out" && pwd)
: >"$out/results.jsonl"
default_timeout=$(case "$level" in fast) echo 1800 ;; stress) echo 10800 ;; soak) echo $((duration + 1800)) ;; esac)
cat_timeout=${cat_timeout:-$default_timeout}

ulimit -c unlimited 2>/dev/null || true
ulimit -n 4096 2>/dev/null || true
{
    echo "RayWM torture suite: level=$level seed=$seed categories=$categories${case_filter:+ case=$case_filter}"
    echo "bin=$bin$( [ -n "$baseline" ] && echo " baseline=$baseline")"
    echo "commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)$(git -C "$root" diff --quiet 2>/dev/null || echo ' (with local changes)')"
    echo "host=$(uname -srm) cpus=$(nproc) renderer=${RENDERER:-pixman} started=$(date -Iseconds)"
} | tee "$out/summary.txt"

status=0
for c in $categories; do
    script="$root/tests/stress/cat/$c.sh"
    [ -f "$script" ] || { echo "run.sh: unknown category $c"; status=2; continue; }
    echo "== $c" | tee -a "$out/summary.txt"
    t0=$(date +%s)
    st=0
    env BIN="$bin" STRESS_OUT="$out" STRESS_SEED="$seed" STRESS_LEVEL="$level" STRESS_CASE="$case_filter" \
        ${iterations:+STRESS_ITER=$iterations} STRESS_DURATION="$duration" STRESS_RSS_CAP_KB="$rss_cap" \
        ${baseline:+BASELINE_BIN=$baseline} category="$c" \
        timeout --signal=TERM --kill-after=30 "$cat_timeout" sh "$script" >"$out/$c.log" 2>&1 || st=$?
    grep -E '^(ok|FAIL|     )' "$out/$c.log" | tee -a "$out/summary.txt" | grep -E '^(ok|FAIL)' | cut -c1-160 || true
    case "$st" in
        0) echo "   $c: OK ($(( $(date +%s) - t0 )) s)" | tee -a "$out/summary.txt" ;;
        124|137) echo "   $c: TIMEOUT after ${cat_timeout} s (category killed; see $out/$c.log)" | tee -a "$out/summary.txt"; status=1
            printf '{"category": "%s", "case": "(category)", "seed": %s, "level": "%s", "status": "timeout", "duration_ms": %s}\n' "$c" "$seed" "$level" "$(( ($(date +%s) - t0) * 1000 ))" >>"$out/results.jsonl" ;;
        2) echo "   $c: NOT RUN (environment: $(tail -1 "$out/$c.log"))" | tee -a "$out/summary.txt" ;;
        *) echo "   $c: FAILED ($(( $(date +%s) - t0 )) s)" | tee -a "$out/summary.txt"; status=1 ;;
    esac
done

python3 - "$out" <<'PY' | tee -a "$out/summary.txt"
import json, sys, os
out = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(out, "results.jsonl")) if l.strip()]
passed = sum(r["status"] == "pass" for r in rows)
failed = [r for r in rows if r["status"] != "pass"]
print("cases: %d, passed %d, failed %d" % (len(rows), passed, len(failed)))
for r in failed:
    print("FAILED %s/%s seed=%s: %s" % (r["category"], r["case"], r["seed"], r.get("notes", "")[:200]))
    if "reproduce" in r: print("  reproduce: %s" % r["reproduce"])
    if "logs" in r: print("  logs: %s" % r["logs"])
PY
echo "results: $out/results.jsonl" | tee -a "$out/summary.txt"
exit $status

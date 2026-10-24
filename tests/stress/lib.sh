# Shared helpers of the torture suite (tests/stress/run.sh, docs/TORTURE.md).
# Sourced by tests/stress/cat/*.sh, never run directly.
#
# Every session is isolated like the other suites: private XDG_RUNTIME_DIR,
# scrubbed environment, headless outputs, test build with virtual input.
# Logs stay in $STRESS_OUT/<case>/ (never deleted by the suite).
#
# Environment from the runner:
#   BIN            test build bin directory (zig build -Dtest-input)
#   STRESS_OUT     result directory (results.jsonl, one directory per case)
#   STRESS_SEED    master seed of this run
#   STRESS_LEVEL   fast | stress | soak
#   STRESS_RSS_CAP_KB  fail a case whose compositor RSS exceeds this
#   STRESS_HANG_S  an IPC request slower than this counts as a hang
set -eu
: "${BIN:?}" "${STRESS_OUT:?}" "${STRESS_SEED:=1}" "${STRESS_LEVEL:=fast}"
: "${STRESS_RSS_CAP_KB:=524288}" "${STRESS_HANG_S:=10}"
root=${STRESS_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}
stress_root="$root/tests/stress"
failures=0
category=${category:-$(basename "$0" .sh)}
pid=; rpid=; sampler_pid=
# Whatever happens (set -e, a signal, the runner's timeout), never leave a
# compositor or a sampler behind.
# (Each command guarded: under set -e a failing last command of an && list
# would end the shell with status 1 from inside the EXIT trap.)
cleanup() {
    if [ -n "$sampler_pid" ]; then kill -9 "$sampler_pid" 2>/dev/null || true; fi
    if [ -n "$pid" ]; then kill -9 "$pid" 2>/dev/null || true; pkill -9 -P "$pid" 2>/dev/null || true; fi
    if [ -n "${dir:-}" ] && [ -d "$dir" ]; then pkill -9 -f "$dir/" 2>/dev/null || true; fi
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# level_pick FAST STRESS SOAK: the value for the current level.
level_pick() {
    case "$STRESS_LEVEL" in fast) echo "$1" ;; stress) echo "$2" ;; *) echo "$3" ;; esac
}
now_ms() { date +%s%3N; }

# want_case NAME: false when STRESS_CASE selects other cases (substring).
want_case() { case "$1" in *"${STRESS_CASE:-}"*) return 0 ;; esac; return 1; }

# case_begin NAME SEED: a fresh directory and bookkeeping for one case.
case_begin() {
    case_name=$1; case_seed=$2
    dir="$STRESS_OUT/$category-$(printf '%s' "$case_name" | tr -c 'A-Za-z0-9_.-' '_')-$case_seed"
    [ -d "$dir" ] && chmod -R u+rwX "$dir" 2>/dev/null; rm -rf "$dir"; mkdir -p "$dir/config/raywm/plugins"; chmod 700 "$dir"
    case_failures=0; case_notes=""; case_t0=$(now_ms); pid=; rpid=
    echo "case $category/$case_name seed=$case_seed" >"$dir/case.txt"
}
# fail MESSAGE: records a failure of the current case (does not exit).
fail() {
    echo "FAIL [$category/$case_name seed=$case_seed] $1"
    echo "FAIL $1" >>"$dir/failures.txt"
    case_failures=$((case_failures + 1)); failures=$((failures + 1))
}
# phase NAME: a timestamped marker in phases.txt (to correlate samples).
phase() { echo "t=$(now_ms) $1 fds=$(fds_now)" >>"$dir/phases.txt"; }
note() { case_notes="$case_notes${case_notes:+; }$1"; echo "     $1"; }

json_str() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
# case_end: one JSON line in results.jsonl and a human summary line.
case_end() {
    [ -n "${pid:-}" ] && stress_kill
    ms=$(($(now_ms) - case_t0))
    status=$([ "$case_failures" -eq 0 ] && echo pass || echo fail)
    peak=$(awk 'NR > 1 && $2 > m {m = $2} END {print m + 0}' "$dir/samples.tsv" 2>/dev/null || echo 0)
    fds=$(awk 'NR > 1 && $3 > m {m = $3} END {print m + 0}' "$dir/samples.tsv" 2>/dev/null || echo 0)
    printf '{"category": "%s", "case": %s, "seed": %s, "level": "%s", "status": "%s", "duration_ms": %s, "failures": %s, "peak_rss_kb": %s, "peak_fds": %s, "notes": %s, "logs": %s, "reproduce": %s}\n' \
        "$category" "$(json_str "$case_name")" "$case_seed" "$STRESS_LEVEL" "$status" "$ms" "$case_failures" "$peak" "$fds" \
        "$(json_str "$case_notes")" "$(json_str "$dir")" \
        "$(json_str "tests/stress/run.sh --level $STRESS_LEVEL --category $category --case '$case_name' --seed $case_seed ${repro_extra:-}")" >>"$STRESS_OUT/results.jsonl"
    if [ "$status" = pass ]; then echo "ok   [$category/$case_name seed=$case_seed] $((ms / 1000)) s"
    else echo "     logs: $dir"; fi
}

# ---- the compositor -----------------------------------------------------------

# start INIT.lua [OUTPUTS] [CONF]: compositor with the shipped plugins, the
# torture plugins and INIT as init.lua. Extra env: COMPOSITOR_ENV.
start() {
    cp "$root/config/plugins/"*.lua "$stress_root/plugins/"*.lua "$dir/config/raywm/plugins/"
    cp "$1" "$dir/config/raywm/init.lua"
    [ -n "${3:-}" ] && cp "$3" "$dir/config/raywm/raywm.conf"
    outputs=${2:-1}
    # shellcheck disable=SC2086 # COMPOSITOR_ENV is a list of VAR=value words
    env -i PATH="$PATH" HOME="$dir" XDG_RUNTIME_DIR="$dir" XDG_CONFIG_HOME="$dir/config" \
        RAYWM_STRESS_DIR="$dir" RAYWM_CHAOS_SEED="$case_seed" RAYWM_SYSTEM_CONF= MALLOC_PERTURB_=165 \
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS="$outputs" WLR_RENDERER="${RENDERER:-pixman}" WLR_LIBINPUT_NO_DEVICES=1 \
        RAYWM_XWAYLAND="${RAYWM_XWAYLAND:-0}" ${COMPOSITOR_ENV:-} \
        timeout "${SESSION_TIMEOUT:-3600}" "$BIN/raywm" -s "echo \$WAYLAND_DISPLAY >'$dir/display'" >"$dir/raywm.log" 2>&1 &
    pid=$!
    i=0
    while [ ! -s "$dir/display" ]; do
        i=$((i + 1))
        if [ $i -gt 200 ] || ! kill -0 "$pid" 2>/dev/null; then fail "compositor did not start"; tail -20 "$dir/raywm.log"; pid=; return 1; fi
        sleep 0.05
    done
    # The compositor process: the raywm whose environment names this case
    # (also under a wrapper such as gdb, where it is not a direct child).
    rpid=
    for c in $(pgrep -x raywm); do
        if tr '\0' '\n' <"/proc/$c/environ" 2>/dev/null | grep -qx "RAYWM_STRESS_DIR=$dir"; then rpid=$c; break; fi
    done
    printf 't_ms\trss_kb\tfds\tcpu_ticks\tthreads\n' >"$dir/samples.tsv"
    sample
    sampler </dev/null >/dev/null 2>&1 &
    sampler_pid=$!
}
display_name() { cat "$dir/display"; }
alive() { [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null; }
# One resource sample of the compositor process.
sample() {
    alive || return 0
    rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$rpid/status" 2>/dev/null || echo 0)
    th=$(awk '/^Threads:/ {print $2}' "/proc/$rpid/status" 2>/dev/null || echo 0)
    nfd=$(ls "/proc/$rpid/fd" 2>/dev/null | wc -l)
    cpu=$(awk '{print $14 + $15}' "/proc/$rpid/stat" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\t%s\n' "$(now_ms)" "$rss" "$nfd" "$cpu" "$th" >>"$dir/samples.tsv"
    # Each change of the descriptor count, with what is open (diagnostics).
    if [ "$nfd" != "${last_nfd:-}" ]; then
        { echo "t=$(now_ms) fds=$nfd"; fd_list | uniq -c; } >>"$dir/fds-timeline.txt"
        last_nfd=$nfd
    fi
}
sampler() {
    while alive; do
        sample
        r=$(tail -1 "$dir/samples.tsv" | cut -f2)
        if [ "${r:-0}" -gt "$STRESS_RSS_CAP_KB" ]; then echo "RSS cap exceeded: $r kB" >>"$dir/failures.txt"; kill -ABRT "$rpid" 2>/dev/null; fi
        sleep "${SAMPLE_S:-1}"
    done
}
rss_now() { awk '/^VmRSS:/ {print $2}' "/proc/$rpid/status" 2>/dev/null || echo 0; }
fds_now() { ls "/proc/$rpid/fd" 2>/dev/null | wc -l; }
# What each descriptor of the compositor refers to (sorted, without numbers).
fd_list() { for f in /proc/"$rpid"/fd/*; do readlink "$f"; done 2>/dev/null | sed 's/\[[0-9]*\]/[]/' | sort; }
cpu_ticks() { awk '{print $14 + $15}' "/proc/$rpid/stat" 2>/dev/null || echo 0; }

# ipc ARGS: raywmctl against this session, bounded by STRESS_HANG_S.
ipc() {
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" \
        timeout "$STRESS_HANG_S" python3 "$root/scripts/raywmctl" "$@"
}
# health LABEL: alive and answering IPC in time; records the latency.
health() {
    if ! alive; then fail "compositor died ($1)"; tail -30 "$dir/raywm.log"; return 1; fi
    t=$(now_ms)
    if ! ipc windows >"$dir/health.json" 2>"$dir/health.err"; then
        if alive; then fail "compositor unresponsive: IPC took more than ${STRESS_HANG_S}s ($1)"; else fail "compositor died ($1)"; fi
        return 1
    fi
    echo "$1 $(($(now_ms) - t))" >>"$dir/ipc-latency.txt"
}
# drive ARGS: the virtual input driver.
drive() {
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" RAYWM_TEST_EXTENT="$((1280 * ${outputs:-1}))x720" \
        timeout 120 "$BIN/raywm-test-input" "$@" >>"$dir/driver.log" 2>&1
}
# client LOG VAR=value...: a client in the background; $! is the client.
client() {
    log=$1; shift
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$(display_name)" "$@" >"$dir/$log" 2>&1 &
}
# wait_for FILE PATTERN SECONDS
wait_for() {
    w=0; lim=$(($3 * 20))
    until grep -q "$2" "$dir/$1" 2>/dev/null; do w=$((w + 1)); [ $w -gt $lim ] && return 1; sleep 0.05; done
}
# wait_pids SECONDS PIDS...: waits for clients; kills and reports stragglers.
wait_pids() {
    lim=$(($1 * 20)); shift
    w=0
    for p in "$@"; do
        while kill -0 "$p" 2>/dev/null; do w=$((w + 1)); [ $w -gt $lim ] && break; sleep 0.05; done
    done
    for p in "$@"; do
        if kill -0 "$p" 2>/dev/null; then fail "client $p did not finish (hang?)"; kill -9 "$p" 2>/dev/null || true; fi
    done
}

stress_kill() {
    kill -9 "$sampler_pid" 2>/dev/null || true
    kill -9 "$pid" 2>/dev/null || true
    pkill -9 -P "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=
}

# stop [EXPECTED_ERRORS_REGEX]: SIGTERM, bounded wait, exit status, log scan
# (panics, error(...) lines not matching the expected ones, leak reports).
stop() {
    alive || { fail "compositor was not running at stop"; }
    kill -TERM "$pid" 2>/dev/null || true
    w=0
    while kill -0 "$pid" 2>/dev/null; do
        w=$((w + 1))
        if [ $w -gt 400 ]; then
            fail "shutdown hang: still running 20 s after SIGTERM"
            kill -ABRT "$rpid" 2>/dev/null || true; sleep 1
            break
        fi
        sleep 0.05
    done
    status=0; wait "$pid" || status=$?
    kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true
    pid=
    case "$status" in
        0) ;;
        3) fail "leak-check: memory still allocated at exit" ;;
        124) fail "session timeout (SESSION_TIMEOUT)" ;;
        *) fail "raywm exited with $status" ;;
    esac
    if grep -q "RSS cap exceeded" "$dir/failures.txt" 2>/dev/null; then fail "$(grep -m1 'RSS cap' "$dir/failures.txt")"; fi
    if grep -qE 'panic|reached unreachable|Segmentation fault|General protection|integer overflow|index out of bounds|Double free|leaked:' "$dir/raywm.log"; then
        fail "crash or safety check in compositor log: $(grep -m1 -E 'panic|reached unreachable|Segmentation fault|General protection|integer overflow|index out of bounds|Double free|leaked:' "$dir/raywm.log")"
    fi
    errs=$(grep -E '\[ERROR\]|^error\(' "$dir/raywm.log" | grep -vE "${1:-^$}" || true)
    if [ -n "$errs" ]; then fail "unexpected errors in compositor log: $(printf '%s\n' "$errs" | head -3 | tr '\n' '|')"; fi
}

# check_fds BEFORE AFTER OUTPUTS: no descriptor may outlive the clients,
# except two kinds of bounded, lazily created state (traced with an
# LD_PRELOAD shm_open/open shim, docs/TORTURE-TEST-REPORT.md):
#   * /dev/shm/wlroots-* buffers of the output swapchains (primary and
#     cursor, created by wlr_swapchain_acquire on demand): at most
#     4 per swapchain, 2 swapchains per output;
#   * /dev/urandom, opened once by wlroots' token generator (first
#     ext-foreign-toplevel handle) and kept for the process lifetime.
check_fds() {
    other=$(diff "$1" "$2" | grep '^>' | grep -v '/dev/shm/wlroots-\|/dev/urandom' || true)
    [ -z "$other" ] || fail "file descriptors left after every client went away: $(printf '%s' "$other" | tr '\n' ' ')"
    shm=$(grep -c '/dev/shm/wlroots-' "$2" || true)
    [ "$shm" -le $((8 * $3)) ] || fail "$shm wlroots shm buffers for $3 output(s) (swapchains allow $((8 * $3)))"
    [ "$(grep -c '/dev/urandom' "$2" || true)" -le 1 ] || fail "/dev/urandom opened more than once"
}

# Resource trend of the session: "first..last (peak)" for RSS and FDs.
trend() {
    awk -F'\t' 'NR == 2 {r0 = $2; f0 = $3} NR > 1 {r = $2; f = $3; if ($2 > rp) rp = $2; if ($3 > fp) fp = $3}
        END {printf "RSS %d..%d kB (peak %d), fds %d..%d (peak %d)", r0, r, rp, f0, f, fp}' "$dir/samples.tsv"
}
# CPU seconds used by the compositor since the case started.
cpu_s() { awk -v t="$(cpu_ticks)" -v hz="$(getconf CLK_TCK)" 'BEGIN {printf "%.2f", t / hz}'; }

summary() {
    if [ "$failures" -eq 0 ]; then echo "$category: OK"; else echo "$category: $failures failure(s)"; exit 1; fi
}

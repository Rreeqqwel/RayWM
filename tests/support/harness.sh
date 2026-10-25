# Shared helpers for the headless interaction suites (tests/input.sh,
# tests/pointer.sh, tests/navigation.sh). Sourced by them, never run.
#
# Every session is isolated: private XDG_RUNTIME_DIR, scrubbed environment
# (env -i), headless outputs; the input driver connects only to the test
# compositor's socket, so nothing reaches the running desktop session.
#
# The sourcing script sets $bin (test build bin dir) and $root (repo root).
# Knobs, read by start() (prefix them, e.g. `OUTPUTS=2 start ...`):
#   OUTPUTS=N           headless outputs, 1280x720 each, left to right (1)
#   WIN="VAR=v ..."     environment of the windows that start() opens
#   PLUGINS="dir ..."   extra plugin directories copied into the config
#   DRIVER_ENV="VAR=v"  extra environment of the input driver
#   FLAGS="-d"          extra raywm command-line flags
#   RULES=file          copied to rules.lua (window-rules.lua reads it)
#   CONF=file           copied to raywm.conf (next to init.lua)
#   COMPOSITOR_ENV="VAR=v ..."  extra environment of the compositor. The
#                       system raywm.conf is never read unless this sets
#                       RAYWM_SYSTEM_CONF (sessions stay hermetic).
failures=0
scenarios=0
default_win="RAYWM_TEST_HOLD=1 RAYWM_TEST_CSD_MOVE=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"

# start <config.lua> <windows 0-4> [panel|panel-kbd|panel-ptr]
# Starts the compositor, then an optional panel and N held windows
# (logs: panel.log, a.log .. d.log; pids: *.pid), one after the other.
start() {
    scenarios=$((scenarios + 1))
    before=$failures
    tmp=$(mktemp -d); chmod 700 "$tmp"
    mkdir -p "$tmp/config/raywm/plugins"
    cp "$root/config/plugins/"*.lua "$root/tests/input/plugins/"*.lua "$tmp/config/raywm/plugins/"
    for d in ${PLUGINS:-}; do cp "$d/"*.lua "$tmp/config/raywm/plugins/"; done
    cp "$1" "$tmp/config/raywm/init.lua"
    if [ -n "${RULES:-}" ]; then cp "$RULES" "$tmp/config/raywm/rules.lua"; fi
    if [ -n "${CONF:-}" ]; then cp "$CONF" "$tmp/config/raywm/raywm.conf"; fi
    client="'$bin/raywm-test-client'"
    win="${WIN:-$default_win} $client"
    # Bounded (30 s): the startup command is detached from the compositor,
    # so an endless wait for a client that died outlived the test.
    wait_for() { echo "w=0; until grep -q '$2' '$tmp/$1' || [ \$w -ge 600 ]; do w=\$((w + 1)); sleep 0.05; done"; }
    cmd="echo \$WAYLAND_DISPLAY >'$tmp/display'"
    case "${3:-}" in
        panel) cmd="$cmd; RAYWM_TEST_LAYER=1 RAYWM_TEST_KBD=1 $client >'$tmp/panel.log' 2>&1 & echo \$! >'$tmp/panel.pid'; $(wait_for panel.log 'layer frame done')" ;;
        panel-kbd) cmd="$cmd; RAYWM_TEST_LAYER=1 RAYWM_TEST_LAYER_KBD=1 RAYWM_TEST_KBD=1 $client >'$tmp/panel.log' 2>&1 & echo \$! >'$tmp/panel.pid'; $(wait_for panel.log 'layer frame done')" ;;
        panel-ptr) cmd="$cmd; RAYWM_TEST_LAYER=1 RAYWM_TEST_PTR=1 $client >'$tmp/panel.log' 2>&1 & echo \$! >'$tmp/panel.pid'; $(wait_for panel.log 'layer frame done')" ;;
    esac
    n=0
    for w in a b c d; do
        n=$((n + 1))
        [ "$2" -ge $n ] || break
        cmd="$cmd; $win >'$tmp/$w.log' 2>&1 & echo \$! >'$tmp/$w.pid'; $(wait_for $w.log 'frame done')"
    done
    cmd="$cmd; sleep 0.3; touch '$tmp/ready'"
    # Kept for drive(), which runs after the prefix assignments are gone.
    outputs=${OUTPUTS:-1}
    driver_env=${DRIVER_ENV:-}
    env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" \
        RAYWM_TEST_OUT="$tmp/probe.log" MALLOC_PERTURB_=165 \
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS="$outputs" WLR_RENDERER="${RENDERER:-pixman}" WLR_LIBINPUT_NO_DEVICES=1 \
        WLR_XWAYLAND="${WLR_XWAYLAND:-Xwayland}" RAYWM_XWAYLAND="${RAYWM_XWAYLAND:-1}" \
        RAYWM_SYSTEM_CONF= ${COMPOSITOR_ENV:-} \
        timeout 60 "$bin/raywm" ${FLAGS:-} -s "$cmd" >"$tmp/raywm.log" 2>&1 &
    pid=$!
    i=0
    while [ ! -e "$tmp/ready" ]; do
        i=$((i + 1))
        if [ $i -gt 150 ] || ! kill -0 $pid 2>/dev/null; then
            echo "FAIL [$name] compositor/clients did not start"; cat "$tmp/raywm.log"; exit 1
        fi
        sleep 0.1
    done
}

fail() { echo "FAIL [$name] $1"; failures=$((failures + 1)); }

# drive <args...>: run the input driver against the test compositor only.
drive() {
    # shellcheck disable=SC2086 # driver_env is a list of VAR=value words
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" \
        RAYWM_TEST_EXTENT="$((1280 * outputs))x720" $driver_env \
        "$bin/raywm-test-input" "$@" >>"$tmp/driver.log" 2>&1 || fail "driver: $*"
}
# drive_bg <args...>: like drive, in the background (finish with drive_wait),
# so the test can act (kill a client, unplug an output) while buttons are held.
drive_bg() {
    # shellcheck disable=SC2086
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" \
        RAYWM_TEST_EXTENT="$((1280 * outputs))x720" $driver_env \
        "$bin/raywm-test-input" "$@" >>"$tmp/driver.log" 2>&1 &
    driver_pid=$!
    driver_args=$*
}
drive_wait() { wait "$driver_pid" || fail "driver: $driver_args"; }
dump() { drive key super down key f12 down key f12 up key super up sleep 150; }

# launch <name> <VAR=value...>: one more test client (log: <name>.log).
launch() {
    n=$1; shift
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" "$@" \
        "$bin/raywm-test-client" >"$tmp/$n.log" 2>&1 &
    echo $! >"$tmp/$n.pid"
}
# wait_log <name> <text>: waits up to 5 s for a line in <name>.log.
wait_log() {
    w=0
    until grep -q "$2" "$tmp/$1.log" 2>/dev/null; do
        w=$((w + 1)); [ $w -gt 100 ] && { fail "$1.log: '$2' never appeared"; return 0; }
        sleep 0.05
    done
}
# presses <name> <n>: the client saw exactly n presses of J (keycode 36).
presses() {
    c=$(grep -c "kbd key 36 pressed" "$tmp/$1.log" || true)
    [ "$c" -eq "$2" ] || fail "$1 got $c J presses, expected $2"
}
press_j() { drive sleep 300 key j down key j up sleep 150; }

# has <name> <fixed line>: <name>.log contains the client line exactly.
has() { grep -qxF "client: $2" "$tmp/$1.log" || fail "$1: no '$2'"; }
# lacks <name> <fixed text>: <name>.log has no line containing the text.
lacks() { if grep -qF "$2" "$tmp/$1.log"; then fail "$1: unexpected '$2'"; fi; }
# ptr_after <name> <fixed line>: pointer lines of <name>.log after the
# first occurrence of <line> (the "event stream" since then).
ptr_after() {
    awk -v m="client: $2" '!on && $0 == m {on = 1; next} on && /client: ptr / {print}' "$tmp/$1.log"
}
# unplug <name>: test builds remove the output named in raywm-test-unplug
# on SIGUSR2 (tests/support/virtual_input.zig).
unplug() {
    echo "$1" >"$tmp/raywm-test-unplug"
    pkill -USR2 -P "$pid" -x raywm || fail "could not signal raywm"
}
# plug: test builds add a new 1280x720 headless output on SIGUSR1.
plug() {
    pkill -USR1 -P "$pid" -x raywm || fail "could not signal raywm"
}

stop() {
    kill -TERM $pid 2>/dev/null || true
    status=0; wait $pid || status=$?
    [ "$status" -eq 0 ] || fail "raywm exited with $status"
    log_errors=$(grep -E "panic|\[ERROR\]|error\(" "$tmp/raywm.log" || true)
    if [ -n "${EXPECTED_LOG_ERRORS:-}" ]; then
        printf '%s\n' "$log_errors" | grep -E "$EXPECTED_LOG_ERRORS" | sed 's/^/known upstream diagnostic: /' || true
        log_errors=$(printf '%s\n' "$log_errors" | grep -Ev "$EXPECTED_LOG_ERRORS" || true)
    fi
    if [ -n "$log_errors" ]; then fail "errors in compositor log"; fi
    if [ "$failures" -ne "$before" ]; then
        for f in "$tmp"/*.log; do echo "--- ${f##*/}"; tail -40 "$f"; done
    else echo "ok   [$name]"; fi
    if [ -n "${KEEP:-}" ]; then echo "kept $tmp"; else rm -rf "$tmp"; fi
}

# expect <dump-number> <line>: the probe's dump N contains exactly this line.
expect() {
    awk -v n="dump $1" '$0 == n {on=1; next} /^dump / {on=0} on' "$tmp/probe.log" | grep -qxF "$2" ||
        fail "dump $1: expected '$2'"
}

# run_scenarios <suite> <s1 s2 ...>: runs each scenario function, or only
# those whose name (the `name=` line in its body) contains $ONLY.
run_scenarios() {
    suite=$1; shift
    for s in "$@"; do
        name=$(awk -v f="$s() {" '$0 == f {on = 1; next} on && /^    name="/ {sub(/^    name="/, ""); sub(/"$/, ""); print; exit}' "$0")
        case "$name" in *"${ONLY:-}"*) $s ;; esac
    done
    if [ "$failures" -eq 0 ]; then echo "$suite: OK ($scenarios scenarios)"; else echo "$suite: $failures failure(s) in $scenarios scenarios"; exit 1; fi
}

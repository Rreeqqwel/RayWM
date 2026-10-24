#!/bin/sh
# Crash and recovery:
#   start-stop        many start/stop cycles (SIGTERM and SIGINT): each exits
#                     0 quickly, leaves no child process behind
#   shutdown-busy     SIGTERM while clients hold windows, popups, layer
#                     surfaces and unacknowledged configures: clean exit,
#                     every client sees the disconnect and ends
#   init-failures     broken environments (no runtime dir, unwritable runtime
#                     dir, unknown backend, no outputs, unreadable or
#                     directory configuration): a clear message, no crash,
#                     and (where it can run) a working compositor
#   ipc-abuse         garbage, oversized and partial frames, half-open and
#                     slow connections, the connection limit and abrupt
#                     disconnects, with a well-behaved client still served
. "$(dirname "$0")/../lib.sh"
seed=$STRESS_SEED

c_start_stop() {
    case_begin start-stop "$seed"
    n=$(level_pick 20 100 300); i=0; slow=0; worst=0
    while [ $i -lt "$n" ]; do
        t="$dir/s$i"; mkdir -p "$t/config/raywm/plugins"; chmod 700 "$t"
        cp "$root/config/plugins/"*.lua "$t/config/raywm/plugins/"; cp "$root/config/init.lua" "$t/config/raywm/"
        t0=$(now_ms)
        env -i PATH="$PATH" HOME="$t" XDG_RUNTIME_DIR="$t" XDG_CONFIG_HOME="$t/config" RAYWM_SYSTEM_CONF= RAYWM_XWAYLAND=$((i % 2)) \
            WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=$((i % 3)) WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
            timeout 30 "$BIN/raywm" -s "echo up >'$t/up'" >"$t/raywm.log" 2>&1 &
        p=$!
        w=0; while [ ! -e "$t/up" ] && kill -0 $p 2>/dev/null && [ $w -lt 400 ]; do w=$((w + 1)); sleep 0.02; done
        [ -e "$t/up" ] || { fail "cycle $i: did not start: $(tail -2 "$t/raywm.log" | tr '\n' ' ')"; }
        child=$(pgrep -P $p -x raywm || true)
        kill -"$([ $((i % 2)) -eq 0 ] && echo TERM || echo INT)" "${child:-$p}" 2>/dev/null || true
        st=0; wait $p || st=$?
        ms=$(($(now_ms) - t0)); [ $ms -gt "$worst" ] && worst=$ms
        [ "$st" -eq 0 ] || fail "cycle $i: exit status $st: $(grep -m1 -E 'panic|error|Assert' "$t/raywm.log")"
        if grep -qE 'panic|Segmentation|Assertion|leaked' "$t/raywm.log"; then fail "cycle $i: $(grep -m1 -E 'panic|Segmentation|Assertion|leaked' "$t/raywm.log")"; fi
        # Nothing of this session may survive it (Xwayland, spawned shells).
        if pgrep -f "$t/" >/dev/null; then fail "cycle $i: processes left behind: $(pgrep -af "$t/" | head -2 | tr '\n' ' ')"; pkill -9 -f "$t/"; fi
        [ "$st" -eq 0 ] && rm -rf "$t"
        i=$((i + 1))
    done
    note "$n start/stop cycles (0-2 outputs, Xwayland on/off, SIGTERM/SIGINT); slowest $worst ms"
    case_end
}

c_shutdown_busy() {
    case_begin shutdown-busy "$seed"
    start "$stress_root/config/lifecycle.lua" 2 || { case_end; return; }
    : >"$dir/stop"
    pids=
    for i in 0 1 2 3 4 5; do
        client "c$i.log" RAYWM_CHAOS_SEED=$((seed * 10 + i)) RAYWM_CHAOS_OPS=100000 RAYWM_CHAOS_DELAY_MS=2 "$BIN/raywm-test-chaos"
        pids="$pids $!"
    done
    client hold.log RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 RAYWM_TEST_POPUP=1 "$BIN/raywm-test-client"; pids="$pids $!"
    client panel.log RAYWM_TEST_LAYER=1 "$BIN/raywm-test-client"; pids="$pids $!"
    sleep 1.5
    t0=$(now_ms)
    stop "\\[chaos\\]|\\[audit\\]"
    note "SIGTERM with 8 busy clients: exit after $(($(now_ms) - t0)) ms"
    # shellcheck disable=SC2086
    wait_pids 10 $pids
    for i in 0 1 2 3 4 5; do grep -q 'FAIL disconnected\|FAIL' "$dir/c$i.log" || fail "client $i did not see the compositor go away: $(tail -1 "$dir/c$i.log")"; done
    case_end
}

c_init_failures() {
    case_begin init-failures "$seed"
    try() { # NAME EXPECT(run|fail) ENV...
        nm=$1; expect=$2; shift 2
        t="$dir/$nm"; mkdir -p "$t/config/raywm"; chmod 700 "$t"; printf 'raywm.load("binds")\n' >"$t/config/raywm/init.lua"
        mkdir -p "$t/config/raywm/plugins"; cp "$root/config/plugins/binds.lua" "$t/config/raywm/plugins/"
        [ -n "${PREP:-}" ] && eval "$PREP"
        env -i PATH="$PATH" HOME="$t" XDG_RUNTIME_DIR="$t" XDG_CONFIG_HOME="$t/config" RAYWM_SYSTEM_CONF= RAYWM_XWAYLAND=0 \
            WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 "$@" \
            timeout 20 "$BIN/raywm" -s "echo up >'$dir/$nm.up'" >"$dir/$nm.log" 2>&1 &
        p=$!
        w=0; while [ ! -e "$dir/$nm.up" ] && kill -0 $p 2>/dev/null && [ $w -lt 300 ]; do w=$((w + 1)); sleep 0.02; done
        if [ -e "$dir/$nm.up" ]; then
            child=$(pgrep -P $p -x raywm || true); kill -TERM "${child:-$p}" 2>/dev/null || true
        fi
        st=0; wait $p || st=$?
        if grep -qE 'panic|Segmentation|Assertion|reached unreachable|leaked' "$dir/$nm.log"; then fail "$nm: crash: $(grep -m1 -E 'panic|Segmentation|Assertion|unreachable|leaked' "$dir/$nm.log")"; return; fi
        case "$expect/$st" in
            run/0) [ -e "$dir/$nm.up" ] || fail "$nm: exited 0 without running" ;;
            fail/0) fail "$nm: should have failed but ran" ;;
            fail/124) fail "$nm: hung instead of failing" ;;
            fail/*) [ -s "$dir/$nm.log" ] || fail "$nm: failed without any message" ;;
            *) fail "$nm: exit status $st, expected $expect: $(tail -2 "$dir/$nm.log" | tr '\n' ' ')" ;;
        esac
        note "$nm: exit $st, $(grep -v '^debug' "$dir/$nm.log" | grep -m1 -iE 'error|warn|fail|cannot|unable' | cut -c1-90)"
        chmod -R u+rwX "$t" 2>/dev/null || true
        PREP=
    }
    try no-outputs run WLR_HEADLESS_OUTPUTS=0
    try unknown-backend fail WLR_BACKENDS=nosuchbackend
    PREP='rm -rf "$t/config/raywm"' try no-config run WLR_HEADLESS_OUTPUTS=1
    PREP='rm -rf "$t/config/raywm"; mkdir -p "$t/config"; echo x >"$t/config/raywm"' try config-is-file run WLR_HEADLESS_OUTPUTS=1
    PREP='printf "[general]\nxwayland=true\n" >"$t/config/raywm/raywm.conf"; chmod 000 "$t/config/raywm/raywm.conf"' try unreadable-conf run WLR_HEADLESS_OUTPUTS=1
    PREP='mkdir -p "$t/config/raywm/raywm.conf"' try conf-is-directory run WLR_HEADLESS_OUTPUTS=1
    PREP='chmod 000 "$t/config/raywm/plugins"' try unreadable-plugins run WLR_HEADLESS_OUTPUTS=1
    PREP='printf "\\033Lua\\x54\\x00garbage" >"$t/config/raywm/init.lua"' try binary-init run WLR_HEADLESS_OUTPUTS=1
    # The runtime directory: missing, then not writable.
    try no-runtime-dir fail WLR_HEADLESS_OUTPUTS=1 XDG_RUNTIME_DIR="$dir/does-not-exist"
    mkdir -p "$dir/ro"; chmod 500 "$dir/ro"
    try readonly-runtime-dir fail WLR_HEADLESS_OUTPUTS=1 XDG_RUNTIME_DIR="$dir/ro"
    chmod 700 "$dir/ro"
    case_end
}

c_ipc_abuse() {
    case_begin ipc-abuse "$seed"
    start "$stress_root/config/lifecycle.lua" 1 || { case_end; return; }
    : >"$dir/stop"
    client w.log RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 "$BIN/raywm-test-client"
    wait_for w.log 'frame done' 10 || fail "window did not map"
    sock="$dir/raywm-$(display_name).sock"
    python3 - "$sock" "$seed" $(level_pick 300 3000 10000) >"$dir/ipc-abuse.txt" 2>&1 <<'PY' || fail "IPC abuse driver: $(tail -3 "$dir/ipc-abuse.txt" | tr '\n' ' ')"
import json, os, random, socket, sys, time
path, seed, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
r = random.Random(seed)
def conn():
    s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(path); return s
def good():
    # A full listen backlog (the abuse above) refuses a connect for a moment:
    # retry for up to 2 s; failing longer would be a lasting denial of service.
    for attempt in range(40):
        try:
            s = conn(); break
        except (BlockingIOError, ConnectionRefusedError):
            time.sleep(0.05)
    else:
        raise SystemExit("good client could not connect for 2 s")
    s.sendall(b'{"v": 1, "id": 1, "method": "windows"}\n')
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk: raise SystemExit("good client got EOF")
        data += chunk
    s.close()
    reply = json.loads(data.splitlines()[0])
    if not reply.get("ok"): raise SystemExit("good client got no result: %r" % reply)
held = []
kinds = ["garbage", "huge", "partial", "close_mid", "many_lines", "binary", "deep", "bad_method", "idle_hold", "burst_connect"]
counts = {k: 0 for k in kinds}
t0 = time.time()
for i in range(n):
    k = r.choice(kinds); counts[k] += 1
    try:
        if k == "garbage":
            s = conn(); s.sendall(bytes(r.randrange(256) for _ in range(r.randrange(1, 2000))) + b"\n"); s.close()
        elif k == "huge":
            s = conn(); s.sendall(b'{"id": 1, "method": "windows", "params": "' + b"x" * r.choice([65000, 70000, 300000]) + b'"}\n'); s.close()
        elif k == "partial":
            s = conn(); s.sendall(b'{"id": 1, "meth'); s.close()
        elif k == "close_mid":
            s = conn(); s.sendall(b'{"id": 1, "method": "windows"}\n'); s.shutdown(socket.SHUT_RDWR); s.close()
        elif k == "many_lines":
            s = conn(); s.sendall(b'{"id": 1, "method": "windows"}\n' * r.randrange(1, 300)); s.close()
        elif k == "binary":
            s = conn(); s.sendall(b"\x00" * r.randrange(1, 70000)); s.close()
        elif k == "deep":
            s = conn(); s.sendall(b"[" * r.randrange(1000, 60000) + b"\n"); s.close()
        elif k == "bad_method":
            s = conn(); s.sendall(json.dumps({"id": r.randrange(-5, 5), "method": r.choice(["focus", "nope", "", None, 1]), "params": r.choice([{}, [], {"window": -1}, {"window": 2**40}, None])}).encode() + b"\n"); s.close()
        elif k == "idle_hold":
            # Half-open connections that never send: at most 32 clients exist.
            s = conn(); held.append(s)
            if len(held) > 40: held.pop(0).close()
        elif k == "burst_connect":
            ss = [conn() for _ in range(r.randrange(1, 50))]
            for s in ss: s.close()
    except (ConnectionError, socket.timeout, OSError):
        pass  # refused or reset by the compositor: allowed
    if i % 25 == 0:
        for h in held: h.close()
        held = []
        good()
for h in held: h.close()
good()
print("abuse", n, "in %.1f s" % (time.time() - t0), json.dumps(counts))
PY
    health after-abuse
    note "$(tail -1 "$dir/ipc-abuse.txt"); $(trend)"
    stop "\\[chaos\\]|\\[audit\\]"
    case_end
}

for c in start-stop shutdown-busy init-failures ipc-abuse; do
    want_case "$c" && "c_$(echo "$c" | tr - _)"
done
summary

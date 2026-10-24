#!/bin/sh
# Gaming-path regressions (v0.2.1): stable properties, never FPS targets.
# Isolated headless sessions (pixman by default, RENDERER=gles2 for a
# render node); nothing reaches the user's desktop.
#   zig build -Dtest-input -p zig-out/test-input
#   tests/perf.sh zig-out/test-input/bin
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-perf" ] || { echo "perf: build with -Dtest-input"; exit 2; }
. "$root/tests/support/harness.sh"
cfg="$root/tests/perf/init.lua"
tearing_cfg="$root/tests/perf/tearing.lua"
plugins="$root/tests/perf/plugins"

env_in() {
    env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" "$@"
}
# perf <file>: raywmctl perf output saved as <file>.json in the session.
perf() { env_in python3 "$root/scripts/raywmctl" perf >"$tmp/$1.json" 2>&1 || fail "raywmctl perf failed: $(cat "$tmp/$1.json")"; }
# field <file> <python expression over j> : prints the value.
field() { python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$tmp/$1.json"; }
# client <name> <args...>: raywm-test-perf in the session, result in <name>.log
client() { n=$1; shift; env_in "$bin/raywm-test-perf" "$@" >"$tmp/$n.log" 2>&1 || fail "perf client $*: $(tail -3 "$tmp/$n.log")"; }
client_bg() { n=$1; shift; env_in "$bin/raywm-test-perf" "$@" >"$tmp/$n.log" 2>&1 & echo $! >"$tmp/$n.pid"; }
# value <log> <key>: key=value from the client's final perf line.
value() { grep '^perf: ' "$tmp/$1.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$2=//p"; }
check() { python3 -c "import sys; sys.exit(0 if ($1) else 1)" || fail "$2 ($1)"; }
truthful() {
    check "$(value "$1" presented) > 0" "$1: nothing presented"
    check "$(value "$1" presented) <= $(value "$1" commits)" "$1: more presented than committed"
    check "$(value "$1" nonmonotonic) == 0" "$1: presentation time went backwards"
    check "$(value "$1" future) == 0" "$1: presentation time in the future"
}
idle_after() {
    perf "$1a"; sleep 1; perf "$1b"
    a=$(field "$1a" "j['outputs'][0]['commits']"); b=$(field "$1b" "j['outputs'][0]['commits']")
    check "$b - $a == 0" "$2: output kept committing on an unchanged scene ($a -> $b)"
}

p1() {
    name="static desktop with a window and a panel does not render"
    start "$cfg" 1 panel
    sleep 0.5
    idle_after idle "static desktop"
    check "$(field idleb "j['outputs'][0]['failed']") == 0" "failed commits"
    stop
}

p2() {
    name="uncapped fullscreen client: truthful feedback, bounded taskbar traffic, idle afterwards"
    start "$cfg" 2 panel
    client_bg watch watch 4
    wait_log watch "perf: ready"
    client spin spin 2 fullscreen
    truthful spin
    check "$(value spin commits) > 300" "uncapped client throttled to $(value spin commits) commits"
    wait "$(cat "$tmp/watch.pid")" || fail "watcher failed"
    # One map plus a few state changes, never one per client commit
    # (v0.2.0 sent title+app_id+done for every window on every commit).
    check "$(value watch title) <= 10" "taskbar titles: $(value watch title)"
    check "$(value watch done) <= 30" "taskbar done events: $(value watch done)"
    idle_after after "after the client exited"
    stop
}

p3() {
    name="frame-callback client gets one callback per presented frame"
    start "$cfg" 0
    client vsync vsync 2 fullscreen
    truthful vsync
    f=$(value vsync frames); p=$(value vsync presented)
    check "$f >= 30" "only $f frame callbacks in 2 s"
    check "abs($f - $p) <= 3" "frames $f vs presented $p"
    check "$(value vsync discarded) <= 2" "discarded $(value vsync discarded)"
    stop
}

p4() {
    name="window animations finish and the output returns to idle"
    start "$cfg" 0
    launch a RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1
    wait_log a "frame done"
    sleep 0.6
    idle_after anim "after the map animation"
    check "$(field animb "j['animations_running']") == 0" "animations still running"
    stop
}

p5() {
    name="tearing only when the output allows it and the fullscreen client asks (v0.2.1)"
    start "$cfg" 0
    perf t0
    client hint spin 1 fullscreen tearing
    perf t1
    check "$(field t1 "j['tearing_control']")" "tearing-control not advertised"
    check "$(field t1 "j['outputs'][0]['tearing_commits'] + j['outputs'][0]['tearing_rejected']") == 0" "tearing attempted without allow_tearing"
    stop
    PLUGINS=$plugins start "$tearing_cfg" 0
    perf u0
    check "$(field u0 "j['outputs'][0]['allow_tearing']")" "allow_tearing not applied"
    client plain spin 1 fullscreen
    perf u1
    check "$(field u1 "j['outputs'][0]['tearing_commits'] + j['outputs'][0]['tearing_rejected']") == 0" "tearing attempted without the client hint"
    client hint spin 1 fullscreen tearing
    perf u2
    # Headless may accept or reject async flips; either way the policy asked.
    check "$(field u2 "j['outputs'][0]['tearing_commits'] + j['outputs'][0]['tearing_rejected']") > 0" "allowed + async hint never requested tearing"
    check "$(field u2 "j['outputs'][0]['failed']") == 0" "failed commits with tearing"
    client windowed spin 1 tearing
    perf u3
    d=$(python3 -c "import json; a=json.load(open('$tmp/u2.json'))['outputs'][0]; b=json.load(open('$tmp/u3.json'))['outputs'][0]; print((b['tearing_commits']+b['tearing_rejected'])-(a['tearing_commits']+a['tearing_rejected']))")
    check "$d == 0" "tearing requested for a window that is not fullscreen"
    stop
}

p6() {
    name="session lock while a fullscreen client renders uncapped"
    start "$cfg" 0
    client_bg spin spin 3 fullscreen tearing
    sleep 0.5
    env_in "$bin/raywm-test-lock" >"$tmp/lock.log" 2>&1 &
    echo $! >"$tmp/lock.pid"
    wait_log lock "locked"
    sleep 0.5
    perf locked
    check "$(field locked "j['session_locked']")" "not locked"
    check "not $(field locked "j['outputs'][0]['fullscreen_window']") or $(field locked "j['session_locked']")" "lock state"
    wait "$(cat "$tmp/spin.pid")" || fail "spin client failed under lock"
    check "$(value spin nonmonotonic) == 0" "presentation time went backwards"
    kill "$(cat "$tmp/lock.pid")" 2>/dev/null || true
    stop
}

p7() {
    name="output unplugged while a fullscreen client renders uncapped"
    OUTPUTS=2 start "$cfg" 0
    client_bg spin spin 3 fullscreen
    sleep 1
    unplug HEADLESS-1
    sleep 0.5
    perf unplugged
    check "len($(field unplugged "[o['name'] for o in j['outputs']]")) == 1" "output not removed"
    wait "$(cat "$tmp/spin.pid")" || fail "spin client failed across unplug"
    truthful spin
    stop
}

p8() {
    name="perf diagnostics survive clients that disconnect mid-request"
    start "$cfg" 0
    env_in python3 - <<'PY' || fail "disconnect script"
import os, socket
path = os.path.join(os.environ['XDG_RUNTIME_DIR'], 'raywm-' + os.environ['WAYLAND_DISPLAY'] + '.sock')
for i in range(50):
    s = socket.socket(socket.AF_UNIX)
    s.connect(path)
    s.sendall(b'{"v":1,"id":1,"method":"perf"}\n' if i % 2 else b'{"v":1,"id":1,"method":"perf"')
    s.close()
PY
    perf after
    check "$(field after "len(j['outputs'])") == 1" "perf query after disconnects"
    env_in python3 "$root/scripts/raywmctl" perf --bogus >/dev/null 2>&1 && fail "bad arguments accepted"
    stop
}

run_scenarios perf p1 p2 p3 p4 p5 p6 p7 p8

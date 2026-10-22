#!/bin/sh
# Headless focus tests with two windows open at once. Focus is observed by
# the clients themselves (xdg_toplevel "activated" state), so this checks
# what applications actually receive. Isolated like tests/smoke.sh.
#   usage: [RENDERER=pixman|gles2] tests/focus.sh [bin-dir]
set -eu
bin=$(cd "${1:-zig-out/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
failures=0

# run <name> <config-dirs...>: window A stays open, window B maps, acks its
# tile and closes; then the compositor is stopped.
run() {
    name=$1; shift
    tmp=$(mktemp -d); chmod 700 "$tmp"; mkdir -p "$tmp/config/raywm"
    for d in "$@"; do cp -r "$d/." "$tmp/config/raywm/"; done
    client="$bin/raywm-test-client"
    resize_env=; [ -n "${RESIZE:-}" ] && resize_env="RAYWM_TEST_RESIZE=1 "
    env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" \
        RAYWM_TEST_OUT="$tmp/plugin.log" RAYWM_TEST_ROUNDS=1 \
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER="${RENDERER:-pixman}" WLR_LIBINPUT_NO_DEVICES=1 \
        timeout 20 "$bin/raywm" -s "RAYWM_TEST_HOLD=1 '$client' >'$tmp/a.log' 2>&1 & until grep -q 'frame done' '$tmp/a.log'; do sleep 0.05; done; $resize_env'$client' >'$tmp/b.log' 2>&1; echo \$? >'$tmp/b.status'" \
        >"$tmp/raywm.log" 2>&1 &
    pid=$!
    i=0
    while [ ! -s "$tmp/b.status" ] && [ $i -lt 100 ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
    sleep 0.3 # let focus return to A after B closed
    kill -TERM $pid 2>/dev/null || true
    status=0; wait $pid || status=$?
    result=$tmp
}

check() { # file pattern description
    if ! grep -qE "$2" "$1"; then echo "FAIL [$name] $3"; failures=$((failures + 1)); return 1; fi
}
reject() {
    if grep -qE "$2" "$1"; then echo "FAIL [$name] $3"; failures=$((failures + 1)); return 1; fi
}
# Activation history of a client as one line, e.g. "+ - +".
history() { grep -oE "client: (activated|deactivated)" "$1" | sed 's/client: activated/+/;s/client: deactivated/-/' | tr '\n' ' '; }
finish() {
    [ "$status" -eq 0 ] || { echo "FAIL [$name] raywm exited with $status"; failures=$((failures + 1)); }
    if grep -iE "panic|\[ERROR\]|error\(" "$result/raywm.log" >/dev/null; then echo "FAIL [$name] errors in log"; failures=$((failures + 1)); fi
    [ "$(cat "$result/b.status" 2>/dev/null)" = 0 ] || { echo "FAIL [$name] client B failed"; failures=$((failures + 1)); }
    if [ "$failures" -ne "$before" ]; then
        for f in raywm a b plugin; do [ -f "$result/$f.log" ] && { echo "--- $f.log"; tail -20 "$result/$f.log"; }; done
    else echo "ok   [$name]"; fi
    [ -n "${KEEP:-}" ] && echo "kept $result" || rm -rf "$result"
}

# 1. No Lua config: B takes focus from A; A gets it back when B closes.
before=$failures; RESIZE=; export RESIZE
run "no plugin, second window" /nonexistent-empty 2>/dev/null || run "no plugin, second window"
[ "$(history "$result/a.log")" = "+ - + " ] || { echo "FAIL [$name] A activation history: $(history "$result/a.log")"; failures=$((failures + 1)); }
[ "$(history "$result/b.log")" = "+ " ] || { echo "FAIL [$name] B activation history: $(history "$result/b.log")"; failures=$((failures + 1)); }
finish

# 2. A plugin explicitly re-focuses the previous window in view_map.
before=$failures
run "plugin keeps focus" "$root/tests/focus"
[ "$(history "$result/a.log")" = "+ " ] || { echo "FAIL [$name] A activation history: $(history "$result/a.log")"; failures=$((failures + 1)); }
reject "$result/b.log" "client: activated" "B was activated against the plugin's choice"
finish

# 3. Dwindle: B splits A's tile, takes the right half and gets focus.
before=$failures; RESIZE=1
run "dwindle insert and focus" "$root/config" "$root/tests/config"
[ "$(history "$result/b.log")" = "+ " ] || { echo "FAIL [$name] B activation history: $(history "$result/b.log")"; failures=$((failures + 1)); }
check "$result/b.log" "client: round 0 resized 628x704" "B did not get the right half"
check "$result/plugin.log" "^view_resized 3 raywm-test 628x704\+644\+8$" "B not placed at 644,8"
check "$result/plugin.log" "^view_resized 2 raywm-test 628x704\+8\+8$" "A not shrunk to the left half"
check "$result/a.log" "client: hold resized 1264x704" "A not restored to full size after B closed"
finish

[ "$failures" -eq 0 ] && echo "focus: OK" || { echo "focus: $failures failure(s)"; exit 1; }

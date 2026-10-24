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
# tile and closes; then the compositor is stopped. No step depends on a
# sleep being long enough: each waits (bounded) for an observable state.
#   B_CLOSE_WHEN  shell condition; B stays mapped until it holds (the test
#                 client waits for $tmp/close-b), e.g. until A has acked
#                 and committed its new tile. Empty: B closes right away.
#   SETTLED       shell condition for "the compositor is done reacting to
#                 B's close" (e.g. A was resized back); checked before the
#                 compositor is stopped. Empty: a short fixed grace period
#                 (only negative checks follow then).
# Both run with $tmp set; they time out after 10 s and the checks below
# then report what is missing.
wait_until() { # condition
    j=0
    while ! eval "$1" && [ $j -lt 200 ] && kill -0 $pid 2>/dev/null; do sleep 0.05; j=$((j + 1)); done
}
run() {
    name=$1; shift
    tmp=$(mktemp -d); chmod 700 "$tmp"; mkdir -p "$tmp/config/raywm"
    for d in "$@"; do cp -r "$d/." "$tmp/config/raywm/"; done
    client="$bin/raywm-test-client"
    resize_env=; [ -n "${RESIZE:-}" ] && resize_env="RAYWM_TEST_RESIZE=1 "
    [ -n "${B_CLOSE_WHEN:-}" ] && resize_env="${resize_env}RAYWM_TEST_CLOSE_WHEN='$tmp/close-b' "
    env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" \
        RAYWM_TEST_OUT="$tmp/plugin.log" RAYWM_TEST_ROUNDS=1 \
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER="${RENDERER:-pixman}" WLR_LIBINPUT_NO_DEVICES=1 \
        timeout 20 "$bin/raywm" -s "RAYWM_TEST_HOLD=1 '$client' >'$tmp/a.log' 2>&1 & until grep -q 'frame done' '$tmp/a.log'; do sleep 0.05; done; $resize_env'$client' >'$tmp/b.log' 2>&1; echo \$? >'$tmp/b.status'" \
        >"$tmp/raywm.log" 2>&1 &
    pid=$!
    if [ -n "${B_CLOSE_WHEN:-}" ]; then
        wait_until "$B_CLOSE_WHEN"
        : >"$tmp/close-b"
    fi
    wait_until '[ -s "$tmp/b.status" ]'
    if [ -n "${SETTLED:-}" ]; then wait_until "$SETTLED"; else sleep 0.3; fi
    kill -TERM $pid 2>/dev/null || true
    status=0; wait $pid || status=$?
    result=$tmp
}

# Record a failure and go on (set -e must not end the script before
# finish() prints the logs).
check() { # file pattern description
    if ! grep -qE "$2" "$1"; then echo "FAIL [$name] $3"; failures=$((failures + 1)); fi
}
reject() {
    if grep -qE "$2" "$1"; then echo "FAIL [$name] $3"; failures=$((failures + 1)); fi
}
# Activation history of a client as one line, e.g. "+ - +".
# after <file> <first> <then>: a line matching <then> follows one matching <first>.
after() { sed -n "/$2/,\$p" "$1" 2>/dev/null | tail -n +2 | grep -qE "$3"; }
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
before=$failures; RESIZE=; B_CLOSE_WHEN=
SETTLED='[ "$(history "$tmp/a.log")" = "+ - + " ]'
run "no plugin, second window" /nonexistent-empty 2>/dev/null || run "no plugin, second window"
[ "$(history "$result/a.log")" = "+ - + " ] || { echo "FAIL [$name] A activation history: $(history "$result/a.log")"; failures=$((failures + 1)); }
[ "$(history "$result/b.log")" = "+ " ] || { echo "FAIL [$name] B activation history: $(history "$result/b.log")"; failures=$((failures + 1)); }
finish

# 2. A plugin explicitly re-focuses the previous window in view_map.
before=$failures; SETTLED=
run "plugin keeps focus" "$root/tests/focus"
[ "$(history "$result/a.log")" = "+ " ] || { echo "FAIL [$name] A activation history: $(history "$result/a.log")"; failures=$((failures + 1)); }
reject "$result/b.log" "client: activated" "B was activated against the plugin's choice"
finish

# 3. Dwindle: B splits A's tile, takes the right half and gets focus.
# A acks the configure for its new half asynchronously, in its own process.
# If B closed first, A would legitimately skip the stale 628x704 configure
# and commit 1264x704 directly (xdg-shell lets clients ack only the latest
# one), so the shrink was never observable: the old CI flake. B therefore
# stays mapped until the compositor saw A commit its half, and it is
# stopped only once A has been resized back.
before=$failures; RESIZE=1
# The compositor's own record (line-buffered plugin log) that A committed
# its half: the client's log line is written before its commit is sent.
B_CLOSE_WHEN='grep -q "^view_resized 2 raywm-test 628x704+8+8$" "$tmp/plugin.log" 2>/dev/null'
SETTLED='after "$tmp/a.log" "client: hold resized 628x704" "client: hold resized 1264x704" && [ "$(history "$tmp/a.log")" = "+ - + " ]'
run "dwindle insert and focus" "$root/config" "$root/tests/config"
[ "$(history "$result/b.log")" = "+ " ] || { echo "FAIL [$name] B activation history: $(history "$result/b.log")"; failures=$((failures + 1)); }
check "$result/b.log" "client: round 0 resized 628x704" "B did not get the right half"
check "$result/plugin.log" "^view_resized 3 raywm-test 628x704\+644\+8$" "B not placed at 644,8"
check "$result/plugin.log" "^view_resized 2 raywm-test 628x704\+8\+8$" "A not shrunk to the left half"
after "$result/a.log" "client: hold resized 628x704" "client: hold resized 1264x704" ||
    { echo "FAIL [$name] A not restored to full size after B closed"; failures=$((failures + 1)); }
[ "$(history "$result/a.log")" = "+ - + " ] || { echo "FAIL [$name] A activation history: $(history "$result/a.log")"; failures=$((failures + 1)); }
finish

[ "$failures" -eq 0 ] && echo "focus: OK" || { echo "focus: $failures failure(s)"; exit 1; }

#!/bin/sh
# Headless smoke test. Runs raywm with a virtual output, no GPU and no input
# devices, in a private XDG_RUNTIME_DIR with a scrubbed environment, so the
# user's running session is never touched.
#   usage: [RENDERER=pixman|gles2] [KEEP=1] tests/smoke.sh [bin-dir]
set -eu
bin=$(cd "${1:-zig-out/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'kill "$pid" 2>/dev/null || true; [ -n "${KEEP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"' EXIT
chmod 700 "$tmp"
mkdir -p "$tmp/config/raywm"
# Shipped plugins first, then the test config (init.lua, eventlog) on top.
cp -r "$root/config/plugins" "$tmp/config/raywm/"
cp -r "$root/tests/config/." "$tmp/config/raywm/"

env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" \
    RAYWM_TEST_OUT="$tmp/plugin.log" RAYWM_TEST_RESIZE=1 \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER="${RENDERER:-pixman}" WLR_LIBINPUT_NO_DEVICES=1 \
    timeout 20 "$bin/raywm" -s "grep SigBlk /proc/\$\$/status >'$tmp/sigmask'; RAYWM_TEST_LAYER=1 '$bin/raywm-test-client' >'$tmp/panel.log' 2>&1 & until grep -q 'layer frame done' '$tmp/panel.log'; do sleep 0.05; done; '$bin/raywm-test-client' >'$tmp/client.log' 2>&1; echo \$? >'$tmp/client.status'" \
    >"$tmp/raywm.log" 2>&1 &
pid=$!

i=0
while [ ! -s "$tmp/client.status" ]; do
    i=$((i + 1))
    if [ "$i" -gt 100 ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "FAIL: client did not finish"; cat "$tmp/raywm.log" "$tmp/client.log" 2>/dev/null; exit 1
    fi
    sleep 0.1
done
kill -TERM "$pid"
status=0; wait "$pid" || status=$?
pid=

fail() { echo "FAIL: $1"; echo "--- raywm.log"; cat "$tmp/raywm.log"; echo "--- client.log"; cat "$tmp/client.log"; [ -f "$tmp/plugin.log" ] && { echo "--- plugin.log"; cat "$tmp/plugin.log"; }; exit 1; }
[ "$status" -eq 0 ] || fail "raywm exited with $status"
[ "$(cat "$tmp/client.status")" = 0 ] || fail "client exited with $(cat "$tmp/client.status")"
# SIGINT (bit 2) and SIGTERM (bit 15) must not stay blocked in children
# (sh itself may block SIGCHLD briefly, so only these two are checked).
mask=$(awk '{print $2}' "$tmp/sigmask")
[ $((0x$mask & 0x4002)) -eq 0 ] || fail "spawned process inherited blocked SIGINT/SIGTERM: $mask"
for s in "round 0 configured" "round 0 frame done" "round 0 resized 1264x674" "round 1 configured" "round 1 frame done" "round 1 resized 1264x674" "destroyed"; do
    grep -q "client: $s" "$tmp/client.log" || fail "client step '$s' missing"
done
# Native event order: map -> focus -> unmap, twice, with distinct view ids.
grep -oE "event (view_map|view_focus|view_unmap) id=[0-9]+" "$tmp/raywm.log" | grep -v "id=0" | tr '\n' ' ' >"$tmp/order"
grep -qE "^(event view_map id=([0-9]+) event view_focus id=\2 event view_unmap id=\2 ){2}$" "$tmp/order" || fail "unexpected event order: $(cat "$tmp/order")"
a=$(grep -oE "view_map id=[0-9]+" "$tmp/order" | sort -u | wc -l)
[ "$a" -eq 2 ] || fail "view ids were reused"
if grep -iE "panic|segmentation|AddressSanitizer|\[ERROR\]|error\(" "$tmp/raywm.log"; then fail "errors in compositor log"; fi
if [ -f "$root/tests/config/expected.log" ]; then
    diff -u "$root/tests/config/expected.log" "$tmp/plugin.log" || fail "plugin event log mismatch"
fi
echo "smoke: OK"

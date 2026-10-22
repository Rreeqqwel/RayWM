#!/bin/sh
# Runs every plugin example from docs/API.md (```lua blocks that form a
# plugin) in an isolated headless compositor with a real client, and
# fails if one does not load or raises an error.
#   usage: tests/docs.sh [bin-dir]
set -eu
bin=$(cd "${1:-zig-out/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); chmod 700 "$tmp"
trap '[ -n "${KEEP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config/raywm/plugins"

# Extract the lua blocks that start a plugin (or a helper followed by one).
awk -v dir="$tmp/config/raywm/plugins" '
    /^```lua$/ { inblock = 1; n++; file = sprintf("%s/example%d.lua", dir, n); next }
    /^```$/ && inblock { inblock = 0; close(file); next }
    inblock { print > file }
' "$root/docs/API.md"

: >"$tmp/config/raywm/init.lua"
count=0
for f in "$tmp/config/raywm/plugins/"example*.lua; do
    luac5.4 -p "$f"
    if grep -q "^return {" "$f" && grep -q "api = 1" "$f"; then
        name=$(basename "$f" .lua)
        echo "assert(raywm.load(\"$name\"))" >>"$tmp/config/raywm/init.lua"
        count=$((count + 1))
    else
        rm "$f" # a fragment (e.g. the contract outline), not a plugin
    fi
done
[ "$count" -ge 4 ] || { echo "docs: expected at least 4 plugin examples, found $count"; exit 1; }

env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    timeout 20 "$bin/raywm" -s "'$bin/raywm-test-client' >'$tmp/client.log' 2>&1; echo \$? >'$tmp/client.status'" \
    >"$tmp/raywm.log" 2>&1 &
pid=$!
i=0
while [ ! -s "$tmp/client.status" ]; do
    i=$((i + 1)); [ $i -gt 100 ] && { echo "docs: client did not finish"; cat "$tmp/raywm.log"; exit 1; }
    sleep 0.1
done
kill -TERM $pid; wait $pid || true

loaded=$(grep -c "loaded plugin example" "$tmp/raywm.log" || true)
if [ "$loaded" -ne "$count" ] || grep -E "error\(|panic" "$tmp/raywm.log" >/dev/null; then
    echo "docs: FAIL ($loaded of $count examples loaded)"; grep -E "error|panic|example" "$tmp/raywm.log"; exit 1
fi
grep -q "new window" "$tmp/raywm.log" || { echo "docs: the logging example did not run"; exit 1; }
echo "docs: OK ($count API.md examples loaded and ran without errors)"

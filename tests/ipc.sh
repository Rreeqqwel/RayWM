#!/bin/sh
set -eu
bin=$(cd "${1:-zig-out/ipc/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/support/harness.sh"
name="IPC v1 queries, actions, subscriptions, framing and bounded clients"
WIN="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_ROUNDS=1" PLUGINS="$root/tests/shell/plugins" start "$root/tests/shell/init.lua" 1
socket="$tmp/raywm-$(cat "$tmp/display").sock"
python3 "$root/tests/ipc_test.py" "$socket" "$root" || fail "IPC socket checks"
env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" \
    "$bin/raywm-test-lock" >"$tmp/locker.log" 2>&1 &
locker_pid=$!
wait_log locker "locked"
python3 - "$socket" <<'PY' || fail "IPC actions while locked"
import json, socket, sys
with socket.socket(socket.AF_UNIX) as peer:
    peer.settimeout(3); peer.connect(sys.argv[1])
    stream = peer.makefile('rb')
    for method, params in [('focus', {'window': 11}), ('workspace_activate', {'workspace': 2}),
                           ('window_workspace', {'window': 11, 'workspace': 2})]:
        peer.sendall((json.dumps(dict(v=1, id=1, method=method, params=params))+'\n').encode())
        response = json.loads(stream.readline())
        assert not response['ok'] and response['err'] == 'locked'
    peer.sendall(b'{"v":1,"id":2,"method":"windows"}\n')
    assert json.loads(stream.readline())['ok']
print('ipc: locked actions refused; queries available')
PY
drive key f12 down key f12 up sleep 200
wait "$locker_pid" || fail "locker exit"
stop
[ ! -e "$socket" ] || fail "socket not removed on exit"

name="IPC shutdown preserves a replacement path"
PLUGINS="$root/tests/shell/plugins" start "$root/tests/shell/init.lua" 0
socket="$tmp/raywm-$(cat "$tmp/display").sock"
python3 - "$socket" <<'PY'
import os, sys
os.unlink(sys.argv[1])
with open(sys.argv[1], 'w') as file: file.write('replacement\n')
PY
# Stop checks cleanup; keep this disposable directory until the inode check.
keep_previous=${KEEP:-}
KEEP=1 stop
grep -qx 'replacement' "$socket" || fail "replacement path was removed"
if [ -z "$keep_previous" ]; then rm -rf "$tmp"; fi
[ "$failures" -eq 0 ]

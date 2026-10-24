#!/bin/sh
# Run isolated integration suites; keep complete logs and explicit statuses.
# Usage: [RENDERER=gles2] [SUITES='data effects'] tests/run.sh [BIN_DIR] [LOG_DIR]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
logs=${2:-$(mktemp -d /tmp/raywm-validation.XXXXXX)}
mkdir -p "$logs"
suites=${SUITES:-smoke focus docs input pointer captures navigation windows workspaces rules session outputs devices protocols shell taskbar screenshot stress xwayland data effects ipc perf conf update}
for suite in $suites; do
    case "$suite" in
        smoke|focus|docs|input|pointer|captures|navigation|windows|workspaces|rules|session|outputs|devices|protocols|shell|taskbar|screenshot|stress|xwayland|data|effects|ipc|perf|conf|update) ;;
        *) echo "unknown suite: $suite"; exit 2 ;;
    esac
    [ ! -e "$logs/$suite.log" ] && [ ! -e "$logs/$suite.status" ] || { echo "existing log: $suite"; exit 2; }
done
failed=0
for suite in $suites; do
    status=0
    "$root/tests/$suite.sh" "$bin" >"$logs/$suite.log" 2>&1 || status=$?
    printf '%s\n' "$status" >"$logs/$suite.status"
    if [ "$status" -eq 0 ]; then
        echo "$suite: PASS"
    else
        echo "$suite: FAIL ($status)"
        tail -60 "$logs/$suite.log"
        failed=1
    fi
done
echo "logs: $logs"
exit "$failed"

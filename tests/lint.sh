#!/bin/sh
# Static checks the compiler does not make. Fast, needs no build:
#   tests/lint.sh
#
# bool arguments of C functions: Zig 0.16.0 passes them without zero
# extension (src/cabi.zig, ziglang/zig#35373), so C may read a false as
# true. A wlroots function whose last parameter is a bool is called with a
# literal true/false, or through cabi.call(). The names below are those of
# zig-wlroots; toplevel, foreign-toplevel and X11 handles are named t,
# handle and xsurface by convention (Zig methods such as View.setFullscreen
# have the same names and are not C calls).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
failures=0

c_only='setEnabled|setSuspended|setInhibited|setAdaptiveSyncEnabled|setWithdrawn|lockAttachRender|lockSoftwareCursors|notifyRing|notifyStrip|sendRing|sendStrip'
shared='setActivated|setResizing|setFullscreen|setMaximized|setMinimized|activate'
calls=$(grep -rnP "\.(?:$c_only)\(|\b(?:t|handle|xsurface)\.(?:$shared)\(" "$root/src" || true)
# Allowed: the bool is a literal (the last argument).
bad=$(printf '%s\n' "$calls" | grep -vP "\.(?:$c_only|$shared)\((?:[^()]*,\s*)?(?:true|false)\)" | grep -v '^$' || true)
if [ -n "$bad" ]; then
    echo "FAIL a C function gets a computed bool; use cabi.call (src/cabi.zig):"
    printf '%s\n' "$bad" | sed "s|^$root/||"
    failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then echo "lint: OK"; else echo "lint: $failures failure(s)"; exit 1; fi

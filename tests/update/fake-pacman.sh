#!/bin/sh
# Stand-in for pacman in tests/update.sh: the installed version lives in
# $FAKE_DB (empty or missing: not installed). Logs every call to $FAKE_LOG.
# FAKE_PACMAN_FAIL=1 makes -U fail. Never touches the channel file: the
# package's scriptlet does that (tested separately).
set -eu
echo "pacman $*" >>"$FAKE_LOG"
case "$1" in
    -Q)
        [ -s "$FAKE_DB" ] || { echo "error: package 'raywm' was not found" >&2; exit 1; }
        echo "raywm $(cat "$FAKE_DB")" ;;
    -Qip) sed '/^--files$/,$d' "$2" ;;
    -Qlp) sed '1,/^--files$/d' "$2" ;;
    -U)
        shift; [ "$1" = --noconfirm ] && shift
        [ -z "${FAKE_PACMAN_FAIL:-}" ] || { echo "error: failed to commit transaction (conflicting files)" >&2; exit 1; }
        sed -n 's/^Version *: //p' "$1" >"$FAKE_DB" ;;
    *) echo "fake-pacman: unsupported $*" >&2; exit 2 ;;
esac

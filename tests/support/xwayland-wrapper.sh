#!/bin/sh
echo $$ >"$XDG_RUNTIME_DIR/xwayland.pid"
exec /usr/bin/Xwayland "$@"

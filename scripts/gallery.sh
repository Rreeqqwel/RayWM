#!/bin/sh
# Regenerates docs/screenshots/: real screenshots of RayWM, taken with grim
# through RayWM's own wlr-screencopy support, in an isolated headless
# session (private XDG_RUNTIME_DIR, scrubbed environment; nothing touches a
# running desktop). Uses the shipped config (dwindle, binds, screenshot)
# and real clients: foot, fuzzel, swaybg.
#   usage: [RENDERER=pixman|gles2] scripts/gallery.sh [bin-dir]
set -eu
bin=$(cd "${1:-zig-out/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/docs/screenshots"
for t in grim foot fuzzel swaybg; do
    command -v "$t" >/dev/null || { echo "gallery: $t is required"; exit 2; }
done
tmp=$(mktemp -d); chmod 700 "$tmp"
# Stopping RayWM ends its clients too.
stop() { pkill -TERM -f "^$bin/raywm -s echo .*$tmp/display" 2>/dev/null || true; }
trap 'stop; [ -n "${KEEP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config/raywm" "$out"
cp -r "$root/config/." "$tmp/config/raywm/"
# Terminal contents: what each window shows.
cat >"$tmp/t1.sh" <<EOF
cd '$root'; printf '\$ cat ~/.config/raywm/init.lua\n'; cat config/init.lua; printf '\n\$ '; exec sleep 600
EOF
cat >"$tmp/t2.sh" <<EOF
cd '$root'; printf '\$ grep -n "ctx.bind" config/plugins/*.lua\n'; grep -n 'ctx.bind' config/plugins/binds.lua config/plugins/dwindle.lua | cut -c1-70; printf '\n\$ '; exec sleep 600
EOF
cat >"$tmp/t3.sh" <<EOF
cd '$root'; printf '\$ grim ~/Pictures/Screenshots/two-windows.png\n\$ ls ~/Pictures/Screenshots\n'; ls "\$HOME/Pictures/Screenshots" 2>/dev/null; printf '\n\$ '; exec sleep 600
EOF
foot="foot -o colors-dark.background=11111b -o font=monospace:size=10"
start="echo \$WAYLAND_DISPLAY >'$tmp/display'
swaybg -c '#313244' >/dev/null 2>&1 &
sleep 1; $foot sh '$tmp/t1.sh' & sleep 0.7; $foot sh '$tmp/t2.sh' & sleep 0.7
mkdir -p \"\$HOME/Pictures/Screenshots\"; grim \"\$HOME/Pictures/Screenshots/two-windows.png\"
$foot sh '$tmp/t3.sh' & sleep 1.5
touch '$tmp/ready'"
env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" LANG=C.UTF-8 \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER="${RENDERER:-pixman}" WLR_LIBINPUT_NO_DEVICES=1 \
    timeout 60 "$bin/raywm" -s "$start" >"$tmp/raywm.log" 2>&1 &
pid=$!
i=0
until [ -e "$tmp/ready" ]; do
    i=$((i + 1)); [ $i -gt 200 ] && { echo "gallery: session did not start"; cat "$tmp/raywm.log"; exit 1; }
    sleep 0.1
done
run() { env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" LANG=C.UTF-8 "$@"; }
run grim -t png "$out/tiling.png"
# A region of the same screen, as Shift+Print would save it.
run grim -g "8,8 628x300" -t png "$out/region.png"
# A layer-shell launcher over the tiled windows (exclusive keyboard),
# with a fixed list instead of the host's installed applications.
printf 'foot\nfuzzel\ngrim\nslurp\nswaybg\nwl-copy\n' | run fuzzel --dmenu --font monospace:size=11 --lines 6 >/dev/null 2>&1 &
sleep 1.5
run grim -t png "$out/launcher.png"
stop
wait "$pid" || true
ls -l "$out"

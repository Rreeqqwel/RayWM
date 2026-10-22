#!/bin/sh
# Screenshot tests with the REAL tools: grim, slurp, wl-copy and wl-paste,
# driven through config/plugins/screenshot.lua by real key presses (virtual
# keyboard/pointer) inside an isolated headless RayWM. A client draws a
# known pattern; every PNG is decoded and its size and pixels are checked
# (tests/support/png_check.py), so an empty or wrong image fails.
#
# Requires the test build:  zig build -Dtest-input -p zig-out/test-input
# and grim, slurp, wl-clipboard and python3.
# Isolation: private XDG_RUNTIME_DIR, scrubbed environment (env -i). Every
# tool is wrapped to record the WAYLAND_DISPLAY and XDG_RUNTIME_DIR it
# used, and the test fails if any of them could reach another session.
#   usage: [RENDERER=pixman|gles2] [KEEP=1] [ONLY=text] tests/screenshot.sh [test-bin-dir]
set -eu
bin=$(cd "${1:-zig-out/test-input/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$bin/raywm-test-screencopy" ] || { echo "screenshot: missing $bin/raywm-test-screencopy (build with -Dtest-input)"; exit 2; }
for t in grim slurp wl-copy wl-paste python3; do
    command -v "$t" >/dev/null || { echo "screenshot: $t is required for these tests"; exit 2; }
done
failures=0
scenarios=0

# start <outputs>: compositor with the screenshot plugin and one window
# showing the test pattern (window A at 540,285 200x150 on the first output).
start() {
    scenarios=$((scenarios + 1))
    before=$failures
    tmp=$(mktemp -d); chmod 700 "$tmp"
    mkdir -p "$tmp/config/raywm/plugins" "$tmp/fakebin" "$tmp/pics"
    cp "$root/config/plugins/screenshot.lua" "$root/tests/screenshot/plugins/"*.lua "$tmp/config/raywm/plugins/"
    cp "$root/tests/screenshot/init.lua" "$tmp/config/raywm/init.lua"
    # Wrappers: the real tools, recording their session and arguments.
    for t in grim slurp wl-copy; do
        real=$(command -v "$t")
        cat >"$tmp/fakebin/$t" <<EOF
#!/bin/sh
printf '%s|%s|%s\n' "\$WAYLAND_DISPLAY" "\$XDG_RUNTIME_DIR" "start \$*" >>'$tmp/$t.log'
'$real' "\$@"; st=\$?
printf '%s|%s|%s\n' "\$WAYLAND_DISPLAY" "\$XDG_RUNTIME_DIR" "exit \$st" >>'$tmp/$t.log'
exit \$st
EOF
    done
    # No desktop notification daemon here: record what would be shown.
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/notify.log"\n' "$tmp" >"$tmp/fakebin/notify-send"
    chmod +x "$tmp/fakebin/"*
    outputs=$1
    extent="$((outputs * 1280))x720"
    client="'$bin/raywm-test-client'"
    env -i PATH="$tmp/fakebin:$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" \
        XDG_PICTURES_DIR="$tmp/pics" MALLOC_PERTURB_=165 \
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS="$outputs" WLR_RENDERER="${RENDERER:-pixman}" WLR_LIBINPUT_NO_DEVICES=1 \
        timeout 120 "$bin/raywm" -s "echo \$WAYLAND_DISPLAY >'$tmp/display'; RAYWM_TEST_HOLD=1 RAYWM_TEST_PATTERN=1 RAYWM_TEST_ROUNDS=1 $client >'$tmp/a.log' 2>&1 & until grep -q 'frame done' '$tmp/a.log'; do sleep 0.05; done; sleep 0.2; touch '$tmp/ready'" \
        >"$tmp/raywm.log" 2>&1 &
    pid=$!
    i=0
    while [ ! -e "$tmp/ready" ]; do
        i=$((i + 1))
        if [ $i -gt 150 ] || ! kill -0 $pid 2>/dev/null; then
            echo "FAIL [$name] compositor/client did not start"; cat "$tmp/raywm.log"; exit 1
        fi
        sleep 0.1
    done
}

fail() { echo "FAIL [$name] $1"; failures=$((failures + 1)); }

# session_env: what every client of the test compositor gets.
session_env() { echo PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")"; }
drive() {
    env -i $(session_env) RAYWM_TEST_EXTENT="$extent" \
        "$bin/raywm-test-input" "$@" >>"$tmp/driver.log" 2>&1 || fail "driver: $*"
}
# A virtual keyboard that stays for a while (wl-copy and wl-paste need a
# seat keyboard to own and read the selection).
hold_keyboard() {
    env -i $(session_env) RAYWM_TEST_EXTENT="$extent" "$bin/raywm-test-input" sleep "$1" >>"$tmp/driver.log" 2>&1 &
}
launch() { # launch <name> <VAR=value...>: another client (log: <name>.log)
    n=$1; shift
    env -i $(session_env) "$@" "$bin/raywm-test-client" >"$tmp/$n.log" 2>&1 &
}
paste() { env -i $(session_env) wl-paste "$@" 2>>"$tmp/wl-paste.log"; }

# wait_for <file> <text> [seconds]: waits for a line in a log file.
wait_for() {
    w=0
    until grep -q "$2" "$tmp/$1" 2>/dev/null; do
        w=$((w + 1)); [ $w -gt $((${3:-10} * 20)) ] && { fail "$1: '$2' never appeared"; return 0; }
        sleep 0.05
    done
}
count() { if [ -f "$tmp/$1" ]; then grep -c "$2" "$tmp/$1" || true; else echo 0; fi; }
shots() { find "$tmp/pics/Screenshots" -name '*.png' 2>/dev/null | wc -l; }
newest() { ls -t "$tmp/pics/Screenshots/"*.png | head -1; }
wait_shots() {
    w=0
    until [ "$(shots)" -ge "$1" ]; do
        w=$((w + 1)); [ $w -gt 200 ] && { fail "expected $1 screenshot(s), found $(shots)"; return 0; }
        sleep 0.05
    done
    sleep 0.2 # the file appears complete (hard link), but let grim's exit be logged
}
png() { python3 -I "$root/tests/support/png_check.py" "$@" >"$tmp/png.out" 2>&1 || fail "$(cat "$tmp/png.out")"; }
# Window A's quadrants, offset by <dx> <dy> into the image.
pattern() {
    echo --pixel $(($1 + 50)),$(($2 + 37)),ff0000 --pixel $(($1 + 150)),$(($2 + 37)),00ff00 \
         --pixel $(($1 + 50)),$(($2 + 112)),0000ff --pixel $(($1 + 150)),$(($2 + 112)),ffffff
}
# slurp is up once its overlay asked for the keyboard; then drag a box.
select_box() { # select_box x1 y1 x2 y2
    wait_for slurp.log "start"
    sleep 0.5
    drive move "$1" "$2" down left move $((($1 + $3) / 2)) $((($2 + $4) / 2)) move "$3" "$4" up left sleep 200
}
press() { # press <keys...> e.g. press ctrl shift print
    down=; up=
    for k; do down="$down key $k down"; up="key $k up $up"; done
    drive $down $up sleep 100
}

stop() {
    # Isolation: every tool ran against this compositor's socket only.
    disp=$(cat "$tmp/display")
    for t in grim slurp wl-copy; do
        [ -f "$tmp/$t.log" ] || continue
        if grep -v "^$disp|$tmp|" "$tmp/$t.log" >/dev/null; then fail "$t ran outside the test session"; fi
    done
    kill -TERM $pid 2>/dev/null || true
    status=0; wait $pid || status=$?
    [ "$status" -eq 0 ] || fail "raywm exited with $status"
    if grep -E "panic|\[ERROR\]|error\(" "$tmp/raywm.log" >/dev/null; then fail "errors in compositor log"; fi
    if [ "$failures" -ne "$before" ]; then
        for f in "$tmp"/*.log; do echo "--- ${f##*/}"; tail -25 "$f"; done
    else echo "ok   [$name]"; fi
    [ -n "${KEEP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}

# ---- Print and Ctrl+Alt+P: full screenshots, unique names ------------------
s1() {
    name="full screenshot: Print and Ctrl+Alt+P save the real screen"
    start 1
    press print
    wait_shots 1
    f1=$(newest)
    png "$f1" --size 1280x720 $(pattern 540 285) --pixel 300,600,000000 --pixel 1200,700,000000
    press ctrl alt p
    wait_shots 2
    f2=$(newest)
    [ "$f1" != "$f2" ] || fail "second screenshot overwrote the first"
    png "$f2" --size 1280x720 $(pattern 540 285)
    case "${f1##*/}" in screenshot-20[0-9][0-9]-[01][0-9]-[0-3][0-9]_[0-2][0-9]-[0-5][0-9]-[0-5][0-9]*.png) ;; *) fail "unexpected name ${f1##*/}" ;; esac
    [ "$(stat -c %a "$f1")" = 600 ] || fail "screenshot is not private (mode $(stat -c %a "$f1"))"
    grep -q "Screenshot saved $f1" "$tmp/notify.log" || fail "no notification for $f1"
    [ -z "$(find "$tmp/pics" -name '.raywm-screenshot*')" ] || fail "temporary file left"
    stop
}

# ---- Shift+Print: interactive region with slurp ---------------------------
s2() {
    name="region: Shift+Print, drag with slurp, exact crop"
    start 1
    press shift print
    select_box 560 300 660 375
    wait_shots 1
    png "$(newest)" --size-near 100x75 --pixel 10,10,ff0000 --pixel 90,10,00ff00 --pixel 10,70,0000ff --pixel 90,70,ffffff
    grep -q "exit 0" "$tmp/slurp.log" || fail "slurp did not succeed"
    stop
}

# ---- cancelled selection ---------------------------------------------------
s3() {
    name="region: Escape cancels, nothing saved or reported"
    start 1
    press shift print
    wait_for slurp.log "start"
    sleep 0.5
    drive sleep 200 key escape down key escape up sleep 300
    wait_for slurp.log "exit"
    sleep 0.5
    grep -q "exit 0" "$tmp/slurp.log" && fail "slurp was not cancelled"
    [ "$(shots)" -eq 0 ] || fail "a cancelled selection saved a file"
    [ "$(count grim.log start)" -eq 0 ] || fail "grim ran after a cancelled selection"
    [ ! -s "$tmp/notify.log" ] || fail "notification after cancel: $(cat "$tmp/notify.log")"
    grep -q "raywm screenshot: selection cancelled" "$tmp/raywm.log" || fail "cancel not logged"
    # The keyboard came back from slurp: bindings and the next shot work.
    press print
    wait_shots 1
    png "$(newest)" --size 1280x720 $(pattern 540 285)
    stop
}

# ---- Ctrl+Print / Ctrl+Shift+Print: Wayland clipboard ----------------------
s4() {
    name="clipboard: Ctrl+Print and Ctrl+Shift+Print copy a PNG"
    start 1
    hold_keyboard 20000
    sleep 0.3
    press ctrl print
    wait_for raywm.log "raywm screenshot: copied to the clipboard"
    paste --list-types >"$tmp/types" 2>&1 || fail "wl-paste --list-types failed"
    grep -qx "image/png" "$tmp/types" || fail "clipboard has no image/png: $(cat "$tmp/types")"
    paste --type image/png >"$tmp/paste1.png" || fail "wl-paste failed"
    png "$tmp/paste1.png" --size 1280x720 $(pattern 540 285)
    press ctrl shift print
    select_box 560 300 660 375
    w=0; until [ "$(count raywm.log 'copied to the clipboard')" -ge 2 ] || [ $w -gt 200 ]; do w=$((w + 1)); sleep 0.05; done
    paste --type image/png >"$tmp/paste2.png" || fail "wl-paste failed"
    png "$tmp/paste2.png" --size-near 100x75 --pixel 10,10,ff0000 --pixel 90,10,00ff00 --pixel 10,70,0000ff
    [ "$(shots)" -eq 0 ] || fail "copying also saved a file"
    [ "$(count notify.log 'Screenshot copied')" -eq 2 ] || fail "expected two copy notifications"
    stop
}

# ---- two outputs -------------------------------------------------------------
s5() {
    name="two outputs: full layout, a region on the second, one across both"
    start 2
    drive move 1900 360 sleep 100   # window B maps on the output under the pointer
    launch b RAYWM_TEST_HOLD=1 RAYWM_TEST_PATTERN=1 RAYWM_TEST_ROUNDS=1
    wait_for b.log "frame done"
    sleep 0.3
    press print
    wait_shots 1
    png "$(newest)" --size 2560x720 $(pattern 540 285) $(pattern 1820 285) --pixel 1279,100,000000 --pixel 1280,100,000000
    press shift print
    select_box 1840 300 1940 375
    wait_shots 2
    png "$(newest)" --size-near 100x75 --pixel 10,10,ff0000 --pixel 90,10,00ff00 --pixel 10,70,0000ff
    # A selection dragged across the border of the two outputs (slurp has
    # one layer surface per output; the implicit pointer grab keeps the
    # drag on the surface where it started). 640..1920 x 300..375: A's
    # green quadrant on the first output, B's red one on the second.
    press shift print
    select_box 640 300 1920 375
    wait_shots 3
    png "$(newest)" --size-near 1280x75 --pixel 50,10,00ff00 --pixel 1230,10,ff0000 --pixel 640,10,000000
    stop
}

# ---- an output disappears while a capture is pending -----------------------
s6() {
    name="output unplugged during a capture request"
    start 2
    env -i $(session_env) "$bin/raywm-test-screencopy" HEADLESS-2 wait "$tmp/go" >"$tmp/copy.log" 2>&1 &
    wait_for copy.log "frame buffer 1280x720"
    unplug HEADLESS-2
    touch "$tmp/go"
    wait_for copy.log "second frame"
    grep -q "^frame failed" "$tmp/copy.log" || fail "copy of an unplugged output did not fail: $(cat "$tmp/copy.log")"
    grep -q "^second frame failed" "$tmp/copy.log" || fail "new request for a removed output did not fail"
    # A copy racing with the unplug: ready or failed, never a crash or hang.
    env -i $(session_env) "$bin/raywm-test-screencopy" HEADLESS-1 now >"$tmp/race.log" 2>&1 &
    wait_for race.log "frame buffer"
    unplug HEADLESS-1
    wait_for race.log "frame \(ready\|failed\)"
    kill -0 $pid 2>/dev/null || fail "compositor died"
    stop
}

# unplug <name>: test builds remove the output named in raywm-test-unplug
# on SIGUSR2 (tests/support/virtual_input.zig).
unplug() {
    echo "$1" >"$tmp/raywm-test-unplug"
    pkill -USR2 -P "$pid" -x raywm || fail "could not signal raywm"
    wait_for raywm.log "unplugging output $1"
}

# ---- unloading the plugin removes its bindings ------------------------------
s7() {
    name="plugin removed by reload: its keys go away, the rest keeps working"
    start 1
    cp "$root/tests/screenshot/init-noshot.lua" "$tmp/config/raywm/init.lua"
    press super f12
    wait_for raywm.log "reloading"
    sleep 0.3
    press print
    press ctrl alt p
    sleep 1
    [ "$(shots)" -eq 0 ] || fail "Print still bound after the plugin was removed"
    [ "$(count raywm.log 'loaded plugin screenshot')" -eq 1 ] || fail "screenshot plugin loaded again"
    [ "$(count raywm.log 'loaded plugin ctl')" -eq 2 ] || fail "ctl plugin not reloaded"
    cp "$root/tests/screenshot/init.lua" "$tmp/config/raywm/init.lua"
    press super f12
    w=0; until [ "$(count raywm.log 'loaded plugin screenshot')" -ge 2 ] || [ $w -gt 100 ]; do w=$((w + 1)); sleep 0.05; done
    press print
    wait_shots 1
    png "$(newest)" --size 1280x720 $(pattern 540 285)
    stop
}

# ---- windows with client-side shadows (geometry inside the surface) -------
s8() {
    name="window geometry offset: content lands at the window position"
    start 1
    # B: the same 200x150 pattern inside a 10 px "shadow" margin; its window
    # geometry excludes the shadow, so B covers A exactly (540,285 200x150)
    # and the shadow is visible around it.
    launch b RAYWM_TEST_HOLD=1 RAYWM_TEST_PATTERN=1 RAYWM_TEST_ROUNDS=1 RAYWM_TEST_SHADOW=10
    wait_for b.log "frame done"
    sleep 0.3
    press print
    wait_shots 1
    png "$(newest)" --size 1280x720 $(pattern 540 285) --pixel 541,286,ff0000 --pixel 738,433,ffffff \
        --pixel 535,280,ff00ff --pixel 745,440,ff00ff --pixel 528,273,000000
    stop
}

for s in s1 s2 s3 s4 s5 s6 s7 s8; do
    name=$(sed -n "s/^    name=\"\(.*\)\"$/\1/p" "$0" | sed -n "${s#s}p")
    case "$name" in *"${ONLY:-}"*) $s ;; esac
done

[ "$failures" -eq 0 ] && echo "screenshot: OK ($scenarios scenarios, renderer ${RENDERER:-pixman})" ||
    { echo "screenshot: $failures failure(s) in $scenarios scenarios"; exit 1; }

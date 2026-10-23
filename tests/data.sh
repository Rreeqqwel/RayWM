#!/bin/sh
set -eu
bin=$(cd "${1:-zig-out/continuation/bin}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/support/harness.sh"
cfg="$root/tests/windows/tiled.lua"
plain="RAYWM_TEST_HOLD=1 RAYWM_TEST_KBD=1 RAYWM_TEST_PTR=1 RAYWM_TEST_ROUNDS=1"
launch_data() {
    n=$1; shift
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" ${DATA_ENV:-} "$bin/raywm-test-data" "$@" >"$tmp/$n.log" 2>&1 &
    echo $! >"$tmp/$n.pid"
    wait_log "$n" "data: ready"
}
has_data() { grep -qF "$2" "$tmp/$1.log" || fail "$1: missing $2"; }
d1() {
    name="cross-client drag delivers UTF-8 bytes with a native input-transparent icon"
    start "$cfg" 0
    launch_data source source
    wait_log source "data: mapped"
    launch_data target target
    wait_log target "data: mapped"
    drive move 300 300 down left sleep 200 move 900 300 sleep 200 up left sleep 300
    wait_log target "data: received raywm-drag-данные"
    wait_log source "data: finished"
    has_data source "data: drop performed"
    stop
}
d2() {
    name="drag leaving every surface cancels without transferring bytes"
    start "$cfg" 0
    launch_data source source
    wait_log source "data: mapped"
    launch_data target target
    wait_log target "data: mapped"
    drive move 300 300 down left sleep 100 move 900 300 sleep 100 move 1279 719 sleep 100 up left sleep 200
    wait_log target "data: leave"
    wait_log source "data: cancelled"
    if grep -q 'data: received' "$tmp/target.log"; then fail "cancel transferred data"; fi
    stop
}
d3() {
    name="source destruction during drag clears grabs and later clicks work"
    start "$cfg" 0
    launch_data source source
    wait_log source "data: mapped"
    launch a $plain
    wait_log a "frame done"
    drive_bg move 300 300 down left sleep 500 move 900 300 up left sleep 100
    wait_log source "data: drag started"
    kill "$(cat "$tmp/source.pid")"
    drive_wait
    drive move 900 300 down left up left sleep 150
    has a "ptr button 272 released window"
    stop
}
d4() {
    name="text-input relay forwards composition, surrounding text and keyboard grabs"
    start "$cfg" 0
    launch_data ime ime "$tmp/ime-command"
    launch_data text text
    wait_log ime "ime: surrounding hello"
    printf 'commit\n' >"$tmp/ime-command"
    wait_log text "text: commit composed"
    has_data text "text: preedit composing"
    has_data text "text: delete 1 0"
    printf 'grab\n' >"$tmp/ime-command"
    sleep 0.2
    drive sleep 200 key j down key j up sleep 150
    wait_log ime "ime: key 36 1"
    # Focus transfer deactivates the previous text input.
    launch a $plain
    wait_log a "frame done"
    wait_log text "text: leave"
    wait_log ime "ime: deactivate"
    commits_before=$(grep -c 'text: commit composed' "$tmp/text.log")
    printf 'commit\n' >"$tmp/ime-command"
    sleep 0.2
    [ "$(grep -c 'text: commit composed' "$tmp/text.log")" -eq "$commits_before" ] || fail "IME committed to unfocused client"
    stop
}
d5() {
    name="one IME per seat, disconnect and text focus recover safely"
    start "$cfg" 0
    launch_data ime ime "$tmp/ime-command"
    launch_data text text
    wait_log ime "ime: activate"
    launch_data second ime
    wait_log second "ime: unavailable"
    kill "$(cat "$tmp/ime.pid")"
    sleep 0.2
    launch_data replacement ime "$tmp/replacement-command"
    wait_log replacement "ime: activate"
    printf 'commit\n' >"$tmp/replacement-command"
    wait_log text "text: commit composed"
    kill "$(cat "$tmp/text.pid")"
    wait_log replacement "ime: deactivate"
    stop
}
d6() {
    name="pointer enter serial cannot authorize a data drag"
    start "$cfg" 0
    DATA_ENV="RAYWM_TEST_BAD_DRAG=1" launch_data source source
    wait_log source "data: mapped"
    drive move 300 300 sleep 100
    wait_log source "data: invalid drag sent"
    wait_log source "data: cancelled"
    launch a $plain
    wait_log a "frame done"
    drive move 900 300 down left up left sleep 150
    has a "ptr button 272 released window"
    stop
}
d7() {
    name="drag target destruction cancels transfer without retaining its surface"
    start "$cfg" 0
    launch_data source source
    wait_log source "data: mapped"
    launch_data target target
    wait_log target "data: mapped"
    drive_bg move 300 300 down left sleep 200 move 900 300 sleep 700 up left sleep 100
    wait_log target "data: enter"
    kill "$(cat "$tmp/target.pid")"
    drive_wait
    wait_log source "data: cancelled"
    launch a $plain
    wait_log a "frame done"
    drive move 900 300 down left up left sleep 150
    has a "ptr button 272 released window"
    stop
}
d8() {
    name="session lock cancels an active data drag and unlock restores normal clicks"
    start "$cfg" 0
    launch_data source source
    wait_log source "data: mapped"
    launch a $plain
    wait_log a "frame done"
    drive_bg move 300 300 down left sleep 700 move 900 300 up left sleep 100
    wait_log source "data: drag started"
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" \
        "$bin/raywm-test-lock" >"$tmp/locker.log" 2>&1 &
    locker_pid=$!
    wait_log locker "locked"
    wait_log source "data: cancelled"
    drive_wait
    drive sleep 300 key f12 down key f12 up sleep 200
    wait "$locker_pid" || fail "locker exit"
    drive move 900 300 down left up left sleep 150
    has a "ptr button 272 released window"
    stop
}
d9() {
    name="IME candidate popup follows the text cursor and disappears with its owner"
    start "$cfg" 0
    launch_data ime ime "$tmp/ime-command"
    launch_data text text
    wait_log ime "ime: activate"
    printf 'popup\n' >"$tmp/ime-command"
    wait_log ime "ime: rectangle"
    sleep 0.2
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" grim "$tmp/popup.png"
    python3 "$root/tests/support/png_check.py" "$tmp/popup.png" --pixel 40,65,ff00ff || fail "candidate popup missing at text cursor"
    kill "$(cat "$tmp/ime.pid")"
    sleep 0.2
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp" WAYLAND_DISPLAY="$(cat "$tmp/display")" grim "$tmp/removed.png"
    python3 "$root/tests/support/png_check.py" "$tmp/removed.png" --pixel 40,65,884422 || fail "candidate popup retained after IME death"
    stop
}
d10() {
    name="IME virtual keyboard reinjection reaches text client without grab feedback"
    start "$cfg" 0
    launch_data ime ime "$tmp/ime-command"
    launch_data text text
    wait_log ime "ime: activate"
    # Create a keyboard and make it current before the input-method grab.
    drive key a down key a up sleep 100
    printf 'grab\n' >"$tmp/ime-command"
    sleep 0.1
    drive key j down key j up sleep 150
    wait_log ime "ime: keymap"
    wait_log ime "ime: key 36 1"
    printf 'virtual\n' >"$tmp/ime-command"
    wait_log text "text: keyboard enter"
    sleep 0.1
    printf 'reinject\n' >"$tmp/ime-command"
    wait_log text "text: key 36 1"
    wait_log text "text: key 36 0"
    [ "$(grep -c 'ime: key 36 1' "$tmp/ime.log")" -eq 1 ] || fail "reinject fed the same input-method grab"
    stop
}
run_scenarios data d1 d2 d3 d4 d5 d6 d7 d8 d9 d10

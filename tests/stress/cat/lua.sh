#!/bin/sh
# Lua plugin torture. Plugins are trusted code, not a sandbox (SECURITY.md),
# but a *buggy* plugin must not take the compositor or other plugins down:
#   failure-modes  50 plugins, each failing differently (error, non-string
#                  errors, endless loops, pcall/coroutine budget evasion,
#                  memory bombs, stack overflow, errors in __gc, bad API
#                  arguments) at load, in setup, in an event, in a timer or
#                  in teardown; with reloads. Only the failing plugin goes
#                  away; none of its callbacks runs after it failed; the
#                  canary plugin keeps getting events and timer ticks; no
#                  callback of an older Lua state runs after a reload.
#   churn          registrations created and cancelled every 2 ms (handlers,
#                  timers, bindings, rectangles, animations) with windows
#                  and reloads; bounded memory, nothing left after reload.
#   overlap        a second layout fighting dwindle over the same windows
#                  and binding the same keys, with chaos clients.
#   reload-storm   reloads every few ms while clients map and unmap.
#   bytecode       corrupted precompiled chunks given as plugin files.
. "$(dirname "$0")/../lib.sh"
reloads=$(level_pick 4 20 60)
seed=$STRESS_SEED

# canary_check: ticks keep coming from the newest generation, and no line of
# an older generation follows the start of a newer one.
canary_check() {
    awk '/^gen [0-9]+ start/ {g = $2; next} $1 == "gen" && $2 < g && $3 != "teardown" {print "stale: " $0; exit 1}' "$dir/canary.log" ||
        fail "a callback of an older Lua state ran after a reload: $(awk '/^gen [0-9]+ start/ {g = $2; next} $1 == "gen" && $2 < g && $3 != "teardown" {print; exit}' "$dir/canary.log")"
    last=$(awk '/start$/ {g = $2} END {print g}' "$dir/canary.log")
    before=$(grep -c "^gen $last tick" "$dir/canary.log" || true)
    sleep 0.5
    after=$(grep -c "^gen $last tick" "$dir/canary.log" || true)
    [ "$after" -gt "$before" ] || fail "canary (generation $last) stopped ticking ($1)"
}
reload_now() {
    r0=$(grep -c 'reloading' "$dir/raywm.log" || true)
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up || true
    w=0; while [ "$(grep -c 'reloading' "$dir/raywm.log" || true)" -le "$r0" ]; do w=$((w + 1)); [ $w -gt 400 ] && { fail "reload $1 not seen"; return 1; }; sleep 0.05; done
}

# ---- failure-modes ---------------------------------------------------------
c_failure_modes() {
case_begin failure-modes "$seed"
modes=""
for where in load setup event timer teardown; do
    for kind in error table_error nil_error spin hog stack pcall_spin coroutine_spin gc_error bad_api; do
        modes="$modes ${where}_$kind"
    done
done
modes="$modes setup_bad_bind"
init="$dir/init.lua"
{ echo 'raywm.load("canary")'; echo 'raywm.load("dwindle")'; echo 'raywm.load("binds")'; } >"$init"
for m in $modes; do echo "raywm.load(\"failing_$m\")" >>"$init"; done
echo 'raywm.load("canary2")' >>"$init"
for m in $modes; do sed "s/@MODE@/$m/" "$stress_root/lua/failing.lua" >"$dir/config/raywm/plugins/failing_$m.lua"; done
cp "$stress_root/lua/canary.lua" "$dir/config/raywm/plugins/"
# A second canary loaded after all the failures (sharing the log): every
# failure at load time must leave the rest of init.lua working.
sed 's/^local name = "canary"/local name = "canary2"/' "$stress_root/lua/canary.lua" >"$dir/config/raywm/plugins/canary2.lua"
STRESS_HANG_S=60 start "$init" 1 || { case_end; return; }
grep -q 'loaded plugin canary2' "$dir/raywm.log" || fail "plugins after the failing ones were not loaded"
[ -s "$dir/canary2.log" ] || fail "canary2 (loaded last) did not run"
r=1
while [ $r -le "$reloads" ]; do
    client "w$r.log" RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 "$BIN/raywm-test-client"
    cp_pid=$!
    wait_for "w$r.log" 'frame done' 30 || fail "window $r did not map (compositor stalled?)"
    sleep 0.5
    health "round $r"
    canary_check "round $r"
    # Failed plugins: no callback after the failure. Count each mode's lines,
    # wait, count again: event/timer failures happened long ago by now.
    for m in $modes; do grep -c "^$m alive" "$dir/failing.log" 2>/dev/null || echo 0; done >"$dir/alive-1"
    sleep 1
    for m in $modes; do grep -c "^$m alive" "$dir/failing.log" 2>/dev/null || echo 0; done >"$dir/alive-2"
    paste -d' ' "$dir/alive-1" "$dir/alive-2" | awk -v m="$modes" 'BEGIN {n = split(m, a, " ")} {i++; if ($2 > $1) print a[i]}' >"$dir/still-alive"
    while read -r m; do
        case "$m" in
            event_*|timer_*|load_*|setup_*) fail "plugin failing_$m still runs callbacks after failing" ;;
        esac
    done <"$dir/still-alive"
    for m in $modes; do
        case "$m" in load_*|setup_*) grep -q "^$m alive" "$dir/failing.log" 2>/dev/null && fail "failing_$m ran callbacks although its load/setup failed" ;; esac
    done
    kill "$cp_pid" 2>/dev/null || true
    echo "=== reload $r" >>"$dir/failing.log"
    reload_now "$r" || break
    r=$((r + 1))
done
health end
canary_check end
errs=$(grep -c '^error(lua): \[failing_' "$dir/raywm.log" || true)
note "$reloads reloads, $errs plugin failures reported; $(trend); cpu $(cpu_s) s"
# Every load/setup/event/timer mode fails once per Lua state (41 of 51),
# teardown modes once per reload.
[ "$errs" -ge $(( (reloads + 1) * 41 )) ] || fail "only $errs plugin failures reported for $((reloads + 1)) loads"
stop 'error\(lua\): \[failing_|torture: |stack traceback|^\s'
case_end
}

# ---- churn -----------------------------------------------------------------
c_churn() {
case_begin churn "$seed"
printf 'raywm.load("canary")\nraywm.load("dwindle")\nraywm.load("binds")\nraywm.load("churn")\nraywm.load("churn2")\n' >"$dir/init.lua"
cp "$stress_root/lua/canary.lua" "$stress_root/lua/churn.lua" "$dir/config/raywm/plugins/"
cp "$stress_root/lua/churn.lua" "$dir/config/raywm/plugins/churn2.lua"
start "$dir/init.lua" 1 || { case_end; return; }
pids=
for i in 1 2 3; do client "c$i.log" RAYWM_CHAOS_SEED=$((seed * 10 + i)) RAYWM_CHAOS_OPS=$(level_pick 300 2000 6000) RAYWM_CHAOS_DELAY_MS=5 "$BIN/raywm-test-chaos"; pids="$pids $!"; done
sleep 2
rss_a=$(rss_now)
r=1
while [ $r -le "$reloads" ]; do sleep 1; reload_now "$r" || break; health "churn reload $r"; r=$((r + 1)); done
# shellcheck disable=SC2086
wait_pids 120 $pids
for i in 1 2 3; do grep -q 'chaos: done' "$dir/c$i.log" || fail "client $i: $(tail -1 "$dir/c$i.log")"; done
canary_check churn
rss_b=$(rss_now)
grep -q 'registration' "$dir/raywm.log" && note "registration warnings: $(grep -c registration "$dir/raywm.log")"
note "rounds $(tail -1 "$dir/churn.log" 2>/dev/null); RSS ${rss_a} -> ${rss_b} kB; $(trend)"
[ $((rss_b - rss_a)) -lt 8192 ] || fail "RSS grew by $((rss_b - rss_a)) kB during churn"
stop
case_end
}

# ---- overlap ---------------------------------------------------------------
c_overlap() {
case_begin overlap "$seed"
printf 'raywm.load("canary")\nraywm.load("workspaces")\nraywm.load("dwindle")\nraywm.load("binds")\nraywm.load("focus")\nraywm.load("second-layout")\nraywm.load("chaos")\nraywm.load("audit")\n' >"$dir/init.lua"
cp "$stress_root/lua/canary.lua" "$stress_root/lua/second-layout.lua" "$dir/config/raywm/plugins/"
COMPOSITOR_ENV="RAYWM_AUDIT_NO_TILING=1 RAYWM_CHAOS_PERIOD_MS=5" start "$dir/init.lua" 1 || { case_end; return; }
pids=
for i in 1 2 3 4; do client "c$i.log" RAYWM_CHAOS_SEED=$((seed * 10 + i)) RAYWM_CHAOS_OPS=$(level_pick 300 1500 4000) RAYWM_CHAOS_TAG=c$i RAYWM_CHAOS_DELAY_MS=4 RAYWM_CHAOS_HOLD="$dir/release" "$BIN/raywm-test-chaos"; pids="$pids $!"; done
for i in 1 2 3 4; do wait_for "c$i.log" 'settled\|FAIL' 120 || fail "client $i did not settle"; grep -q FAIL "$dir/c$i.log" && fail "client $i: $(grep -m1 FAIL "$dir/c$i.log")"; done
: >"$dir/stop"; sleep 0.5
cat "$dir"/c*.log | grep -c '^chaos: mapped ' >"$dir/expect-views"
: >"$dir/audit-request"; wait_for audit.txt 'audit done' 10 || fail "audit did not run"
grep -q VIOLATION "$dir/audit.txt" && fail "audit: $(grep -m1 VIOLATION "$dir/audit.txt")"
grep -q 'already bound' "$dir/raywm.log" || fail "duplicate bindings were not reported"
: >"$dir/release"
# shellcheck disable=SC2086
wait_pids 30 $pids
canary_check overlap
note "$(trend)"
stop '\[chaos\]|\[audit\]'
case_end
}

# ---- reload-storm ----------------------------------------------------------
c_reload_storm() {
case_begin reload-storm "$seed"
COMPOSITOR_ENV="RAYWM_CHAOS_PERIOD_MS=3 RAYWM_CHAOS_RELOAD=$(level_pick 60 100 150)" start "$stress_root/config/lifecycle.lua" 1 || { case_end; return; }
pids=
for i in 1 2 3 4; do client "c$i.log" RAYWM_CHAOS_SEED=$((seed * 10 + i)) RAYWM_CHAOS_OPS=$(level_pick 400 2000 5000) RAYWM_CHAOS_TAG=c$i RAYWM_CHAOS_DELAY_MS=3 RAYWM_CHAOS_HOLD="$dir/release" "$BIN/raywm-test-chaos"; pids="$pids $!"; done
for i in 1 2 3 4; do wait_for "c$i.log" 'settled\|FAIL' 180 || fail "client $i did not settle"; grep -q FAIL "$dir/c$i.log" && fail "client $i: $(grep -m1 FAIL "$dir/c$i.log")"; done
: >"$dir/stop"; sleep 1
cat "$dir"/c*.log | grep -c '^chaos: mapped ' >"$dir/expect-views"
: >"$dir/audit-request"; wait_for audit.txt 'audit done' 10 || fail "audit did not run"
grep -q VIOLATION "$dir/audit.txt" && fail "audit after $(grep -c reloading "$dir/raywm.log") reloads: $(grep -m1 VIOLATION "$dir/audit.txt")"
: >"$dir/release"
# shellcheck disable=SC2086
wait_pids 30 $pids
health end
note "$(grep -c reloading "$dir/raywm.log") reloads with 4 clients; $(trend); cpu $(cpu_s) s"
stop '\[chaos\]|\[audit\]'
case_end
}

# ---- bytecode --------------------------------------------------------------
c_bytecode() {
case_begin bytecode "$seed"
luac=$(command -v luac5.4 || command -v luac)
n=$(level_pick 40 300 1000)
printf 'return { api = 1, setup = function(ctx) ctx.on("view_map", function() end) end }\n' >"$dir/good.lua"
"$luac" -o "$dir/good.luac" "$dir/good.lua"
python3 - "$dir/good.luac" "$dir/corrupt" "$seed" "$n" <<'PY'
import os, random, sys
src, out, seed, n = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
data = open(src, "rb").read()
r = random.Random(seed)
os.makedirs(out, exist_ok=True)
for i in range(n):
    b = bytearray(data)
    for _ in range(r.randrange(1, 6)):
        pos = r.randrange(12, len(b))  # keep the header: the VM must parse it
        b[pos] = r.randrange(256)
    open(os.path.join(out, "c%04d.lua" % i), "wb").write(bytes(b))
PY
crashes=0; rejected=0; loaded=0; i=0
for f in "$dir"/corrupt/*.lua; do
    i=$((i + 1))
    t="$dir/s$i"; mkdir -p "$t/config/raywm/plugins"; chmod 700 "$t"
    cp "$f" "$t/config/raywm/plugins/corrupt.lua"
    printf 'raywm.load("corrupt")\n' >"$t/config/raywm/init.lua"
    env -i PATH="$PATH" HOME="$t" XDG_RUNTIME_DIR="$t" XDG_CONFIG_HOME="$t/config" RAYWM_SYSTEM_CONF= RAYWM_XWAYLAND=0 \
        WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
        timeout 20 "$BIN/raywm" -s "echo up >'$t/up'" >"$t/raywm.log" 2>&1 &
    bp=$!
    w=0; while [ ! -e "$t/up" ] && kill -0 $bp 2>/dev/null && [ $w -lt 200 ]; do w=$((w + 1)); sleep 0.02; done
    kill -TERM $bp 2>/dev/null || true
    st=0; wait $bp || st=$?
    if [ "$st" -ne 0 ]; then
        crashes=$((crashes + 1))
        [ $crashes -le 3 ] && fail "corrupted bytecode $(basename "$f"): raywm exited with $st (kept $t): $(grep -m1 -E 'Segmentation|panic|error' "$t/raywm.log")"
        continue
    fi
    if grep -q 'loaded plugin corrupt' "$t/raywm.log"; then loaded=$((loaded + 1)); else rejected=$((rejected + 1)); fi
    rm -rf "$t"
done
note "$i corrupted chunks: $rejected rejected, $loaded loaded, $crashes crashed the compositor"
[ "$crashes" -eq 0 ] || fail "$crashes of $i corrupted plugin files crashed the compositor"
case_end
}

for c in failure-modes churn overlap reload-storm bytecode; do
    want_case "$c" && "c_$(echo "$c" | tr - _)"
done
summary

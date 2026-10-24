#!/bin/sh
# raywm.conf fuzzing against the real binary (the parser's own invariants
# are unit-tested in src/conf.zig with 20000 seeded inputs):
#   1. `raywm -t` on every generated file (tests/stress/gen.py conf): the
#      status matches the generator's expectation (valid 0, invalid 1), it
#      never crashes, hangs or prints a safety-check panic;
#   2. live reload in one running compositor, file after file: a valid file
#      replaces raywm.settings exactly with what `raywm -t` reports, a
#      rejected one leaves the previous settings untouched (transactional),
#      the plugins come back after each reload, the compositor stays alive
#      and responsive, and RSS stays bounded.
. "$(dirname "$0")/../lib.sh"
count=${STRESS_ITER:-$(level_pick 60 600 3000)}
seed=$STRESS_SEED

case_begin "raywm-t" "$seed"
python3 "$stress_root/gen.py" conf "$seed" "$dir/fuzz" "$count" >"$dir/expect.txt"
bad=0
while read -r name expect; do
    t="$dir/t-$name"; mkdir -p "$t"; cp "$dir/fuzz/$name" "$t/raywm.conf"
    st=0
    env -i PATH="$PATH" HOME="$t" RAYWM_SYSTEM_CONF= timeout 10 "$BIN/raywm" -t -c "$t/init.lua" >"$t/out" 2>&1 || st=$?
    case "$st/$expect" in
        0/valid|1/invalid|0/any|1/any) rm -rf "$t" ;;
        124/*) fail "$name: raywm -t hung"; bad=$((bad + 1)) ;;
        *) fail "$name: raywm -t exited $st, expected $expect (input kept in $t)"; bad=$((bad + 1)) ;;
    esac
    if [ -d "$t" ] && grep -qE 'panic|reached unreachable|Segmentation' "$t/out"; then fail "$name: crash"; fi
done <"$dir/expect.txt"
note "$count files, $(grep -c ' valid$' "$dir/expect.txt") valid, $(grep -c ' invalid$' "$dir/expect.txt") invalid, $(grep -c ' any$' "$dir/expect.txt") either"
case_end

case_begin "live-reload" "$seed"
start "$stress_root/config/reload.lua" 1 || { case_end; summary; }
client w.log RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 "$BIN/raywm-test-client"
wait_for w.log 'frame done' 10 || fail "window did not map"
audit_n=0
audit() {
    audit_n=$((audit_n + 1))
    rm -f "$dir/audit.txt"
    : >"$dir/audit-request"
    wait_for audit.txt "audit done $audit_n " 10 || { fail "audit $audit_n did not run (Lua dead?)"; return 1; }
    grep '^setting ' "$dir/audit.txt" | sed 's/^setting //' >"$dir/live.txt"
}
# The audit plugin restarts its count on every reload.
reload() {
    r0=$(grep -c 'reloading' "$dir/raywm.log" || true)
    drive key ctrl down key alt down key r down key r up key alt up key ctrl up
    w=0; while [ "$(grep -c 'reloading' "$dir/raywm.log" || true)" -le "$r0" ]; do w=$((w + 1)); [ $w -gt 100 ] && { fail "reload not seen"; return 1; }; sleep 0.02; done
    audit_n=0
}
oracle() { # FILE -> expected settings (raywm -t), "rejected" if it is rejected
    t="$dir/oracle"; rm -rf "$t"; mkdir -p "$t"; cp "$1" "$t/raywm.conf"
    if env -i PATH="$PATH" HOME="$t" RAYWM_SYSTEM_CONF= timeout 10 "$BIN/raywm" -t -c "$t/init.lua" >"$t/out" 2>&1; then
        grep -E '^[a-z_]+\.[a-z_]+ = ' "$t/out" | sed 's/ = /=/' | sort
    else echo rejected; fi
}
audit; cp "$dir/live.txt" "$dir/current.txt"
accepted=0; rejected=0; n=0
for f in "$dir"/../"$category-raywm-t-$seed"/fuzz/*.conf; do
    n=$((n + 1))
    cp "$f" "$dir/config/raywm/raywm.conf"
    # general.xwayland is restart-only: a reload keeps the running value.
    oracle "$f" | sed "s/^general.xwayland=.*/$(grep '^general.xwayland=' "$dir/current.txt")/" >"$dir/expected.txt"
    reload || break
    audit || break
    if [ "$(cat "$dir/expected.txt")" = rejected ]; then
        rejected=$((rejected + 1))
        cmp -s "$dir/live.txt" "$dir/current.txt" || { fail "$(basename "$f") was rejected but changed the settings: $(diff "$dir/current.txt" "$dir/live.txt" | grep '^>' | head -2 | tr '\n' ' ')"; cp "$f" "$dir/"; }
    else
        accepted=$((accepted + 1))
        cmp -s "$dir/live.txt" "$dir/expected.txt" || { fail "$(basename "$f") was accepted but not applied exactly: $(diff "$dir/expected.txt" "$dir/live.txt" | grep '^[<>]' | head -2 | tr '\n' ' ')"; cp "$f" "$dir/"; }
        cp "$dir/live.txt" "$dir/current.txt"
    fi
    [ $((n % 50)) -eq 0 ] && health "after $n reloads"
    alive || { fail "compositor died after $(basename "$f")"; break; }
done
health end
note "$n live reloads: $accepted applied, $rejected rejected; $(trend)"
stop 'error\(conf\)'
case_end
summary

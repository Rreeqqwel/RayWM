#!/bin/sh
# Checks that the public surface in the source is documented: Lua API
# names, every ray.conf setting, IPC methods, command-line options and
# source module references. Fast (no build, no compositor); CI runs it
# before the build, and it is the gate for "documentation after each
# update" (AGENTS.md, docs/TESTING.md).
#   usage: tests/docs-sync.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
failed=0

fail() {
    printf 'docs-sync: %s\n' "$1"
    failed=$((failed + 1))
}

# Every name registered on `raywm` or on the plugin `ctx` (src/lua.zig)
# must appear in docs/API.md, qualified or in the tables of its section.
names=$(awk '
    /^        const (globals|globals_v020|globals_later|ctx_fns|ctx_fns_v020) = \.\{/ { on = 1; next }
    on && /^        \}/ { on = 0; next }
    on {
        line = $0
        while (match(line, /\{ "[a-z_]+"/)) {
            print substr(line, RSTART + 3, RLENGTH - 4)
            line = substr(line, RSTART + RLENGTH)
        }
    }
' src/lua.zig | sort -u)
[ -n "$names" ] || fail "no Lua API names found in src/lua.zig (the tables moved; update this script)"
for name in $names; do
    grep -qE "(raywm\.|ctx\.)?${name}\(" docs/API.md ||
        fail "raywm.$name is registered in src/lua.zig but missing from docs/API.md"
done

# Every event name in src/lua.zig needs a row in the API.md event table.
events=$(awk '/pub const Event = enum \{/,/^\};/' src/lua.zig |
    sed -n 's/^ *\([a-z_]*\),$/\1/p' | sort -u)
[ -n "$events" ] || fail "no events found in src/lua.zig (the enum moved; update this script)"
for event in $events; do
    grep -qF "\`$event\`" docs/API.md ||
        fail "event $event is emitted by src/lua.zig but missing from docs/API.md"
done

# Every setting in src/conf.zig needs a row in the CONFIGURATION.md table.
settings=$(awk '
    /^pub const Settings = struct \{/ { settings = 1; next }
    settings && /^\};$/ { settings = 0 }
    settings && /^    pub const [A-Z][a-z]+ = struct \{/ { section = tolower($3) }
    settings && /^        [a-z_]+: / {
        key = $1; sub(":", "", key)
        print section "." key
    }
' src/conf.zig | sort -u)
[ -n "$settings" ] || fail "no settings found in src/conf.zig (the struct moved; update this script)"
for entry in $settings; do
    section=${entry%%.*}
    key=${entry#*.}
    grep -qF "| \`$section\` | \`$key\` |" docs/CONFIGURATION.md ||
        fail "ray.conf setting [$section] $key is missing from docs/CONFIGURATION.md"
done

# Every IPC method needs a row in the IPC.md method table.
methods=$(
    {
        sed -n 's/.*oneOf(method, &\.{\(.*\)}).*/\1/p' src/ipc.zig
        sed -n 's/.*std\.mem\.eql(u8, method, "\([a-z_]*\)").*/\1/p' src/ipc.zig
    } | tr -s ' "{},' '\n' | grep -E '^[a-z_]+$' | sort -u
)
[ -n "$methods" ] || fail "no IPC methods found in src/ipc.zig (the dispatch moved; update this script)"
for method in $methods; do
    grep -qF "| \`$method\` |" docs/IPC.md ||
        fail "IPC method $method is handled in src/ipc.zig but missing from docs/IPC.md"
done

# The shipped client must expose every IPC method.
ctl=$(sed -n 's/.*choices=(\("[a-z_]*"\(, *"[a-z_]*"\)*\)).*/\1/p' scripts/raywmctl |
    tr -s '", ' '\n' | grep -E '^[a-z_]+$' | sort -u)
[ -n "$ctl" ] || fail "no methods found in scripts/raywmctl (update this script)"
for method in $methods; do
    echo "$ctl" | grep -qx "$method" ||
        fail "scripts/raywmctl does not offer IPC method $method"
done

# Every command-line option in the usage text must be in the README list
# and in the INSTALL options table.
options=$(
    {
        sed -n '/^const usage =/,/^;/p' src/main.zig
        grep -oE 'arg, "-[a-zA-Z]"' src/main.zig
    } | grep -oE '[-][a-zA-Z]' | sort -u
)
[ -n "$options" ] || fail "no options found in the usage text of src/main.zig"
for option in $options; do
    grep -qE "\`$option(\`| )" README.md ||
        fail "option $option is in the usage text but missing from README.md"
    grep -qE "\`$option(\`| )" docs/INSTALL.md ||
        fail "option $option is in the usage text but missing from docs/INSTALL.md"
done

# Modules named in the docs must exist. Path-qualified names (for example
# Zig's own lib/compiler/test_runner.zig) are not project references.
problems=$(
    for doc in README.md docs/*.md; do
        grep -ohE '(^|[^A-Za-z0-9_/])[a-z0-9_]+\.zig' "$doc" | sed 's/^[^a-z0-9_]//' | sort -u |
            while read -r module; do
                [ -e "$module" ] || [ -e "src/$module" ] || [ -e "tests/$module" ] ||
                    [ -e "tests/support/$module" ] ||
                    printf 'docs-sync: %s mentions %s, which does not exist\n' "$doc" "$module"
            done
    done
)
if [ -n "$problems" ]; then
    printf '%s\n' "$problems"
    failed=$((failed + $(printf '%s\n' "$problems" | wc -l)))
fi

if [ "$failed" -ne 0 ]; then
    echo "docs-sync: FAIL ($failed problem(s)); update the docs or the check"
    exit 1
fi
echo "docs-sync: OK ($(echo "$names" | wc -w) API names, $(echo "$events" | wc -w) events, $(echo "$settings" | wc -w) settings, $(echo "$methods" | wc -w) IPC methods, $(echo "$options" | wc -w) options)"

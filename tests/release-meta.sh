#!/bin/sh
# Release tag scheme, pacman version order and update metadata
# (scripts/release-meta.py). Needs python3; vercmp (pacman) when present.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
meta="python3 $root/scripts/release-meta.py"
failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
field() { $meta parse "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['$2'])"; }
for t in v0.2.1-beta v0.2.1-beta.2 v0.2.1-beta.10 v0.2.1-stable v1.0.0-stable v0.10.0-beta; do
    $meta parse "$t" >/dev/null || fail "rejected $t"
done
for t in v0.2.1-beta.1 v0.2.1-beta.0 v0.2.1-rc1 v0.2.1-Stable 0.2.1-stable v0.2-beta v01.2.3-beta v0.2.1-beta.02 v0.2.1-stable.2; do
    if $meta parse "$t" >/dev/null 2>&1; then fail "accepted $t"; fi
done
[ "$(field v0.2.1 channel)" = legacy ] || fail "v0.2.1 is legacy"
[ "$(field v0.2.1-beta pkgver)" = 0.2.1beta ] || fail "beta pkgver"
[ "$(field v0.2.1-beta.3 pkgver)" = 0.2.1beta.3 ] || fail "beta.3 pkgver"
[ "$(field v0.2.1-stable pkgver)" = 0.2.1 ] || fail "stable pkgver"
[ "$(field v0.2.1-stable channel)" = stable ] || fail "stable channel"
# Release order must hold for pacman's vercmp: newer always compares greater.
order="v0.2.0-stable v0.2.1-beta v0.2.1-beta.2 v0.2.1-beta.10 v0.2.1-stable v0.2.2-beta v0.2.2-stable v0.2.10-beta v0.3.0-beta v1.0.0-stable"
if command -v vercmp >/dev/null; then
    prev=""
    for t in $order; do
        v=$(field "$t" pacman_version)
        if [ -n "$prev" ] && [ "$(vercmp "$prev" "$v")" -ge 0 ]; then fail "vercmp: $prev is not older than $v ($t)"; fi
        prev=$v
    done
else echo "release-meta: vercmp not installed, order check SKIPPED"; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'payload' >"$tmp/raywm-v0.2.1-beta.tar.gz"
$meta metadata v0.2.1-beta 0123abc "$tmp/b.json" "$tmp/raywm-v0.2.1-beta.tar.gz"
python3 - "$tmp/b.json" <<'PY' || fail "beta metadata"
import json, sys, hashlib
m = json.load(open(sys.argv[1]))
assert m['schema'] == 1 and m['channel'] == 'beta' and m['channels'] == ['beta']
assert m['pacman_version'] == '0.2.1beta-1' and m['commit'] == '0123abc'
assert m['assets'][0]['kind'] == 'source' and m['assets'][0]['sha256'] == hashlib.sha256(b'payload').hexdigest()
PY
printf 'pkg' >"$tmp/raywm-0.2.1-1-x86_64.pkg.tar.zst"
$meta metadata v0.2.1-stable 0123abc "$tmp/s.json" "$tmp/raywm-0.2.1-1-x86_64.pkg.tar.zst"
python3 -c "import json,sys; m=json.load(open(sys.argv[1])); assert m['channels']==['beta','stable'] and m['assets'][0]['kind']=='arch-package'" "$tmp/s.json" || fail "stable metadata"
if $meta check-zon v9.9.9-beta "$root/build.zig.zon" 2>/dev/null; then fail "check-zon accepted a wrong version"; fi
printf '# Changelog\n\n## [v1.2.3] - x\n\nNotes here.\n\n## [v1.2.2]\n\nOld.\n' >"$tmp/CHANGELOG.md"
[ "$($meta notes v1.2.3-beta "$tmp/CHANGELOG.md")" = "Notes here." ] || fail "changelog notes"
if $meta notes v1.2.4-beta "$tmp/CHANGELOG.md" 2>/dev/null; then fail "missing changelog section accepted"; fi
if [ "$failures" -eq 0 ]; then echo "release-meta: OK"; else echo "release-meta: $failures failure(s)"; exit 1; fi

#!/bin/sh
# raywm-update under attack, with a misbehaving local HTTPS server
# (tests/stress/update/server.py, self-signed certificate trusted through
# CURL_CA_BUNDLE), crafted archives and seeded metadata mutations. pacman is
# the fake of tests/update (nothing is ever installed on the host) and every
# run is unprivileged. tests/update.sh covers the functional scenarios; this
# adds what a hostile or broken network can do:
#   http-errors      403/429 (rate limits), 404, 500 from the API and assets
#   redirects        to plain http (must be refused), loops
#   truncated        downloads cut short; bodies larger than announced
#   endless          endless API and asset bodies (size limits)
#   stall            a server that accepts and never answers (must time out)
#   disk-full        the download hits a file-size limit (ulimit -f)
#   traversal        archives with ../, absolute paths, symlinks, hardlinks
#   metadata-fuzz    seeded mutations of raywm-release.json and of the API
#   channel-file     symlinked, huge, binary, directory update.conf
#   downgrade        never an older version, whatever the metadata claims
#   pagination       an API whose pages never end
# Invariants for every run: the exit status is 0, 1 or 2 (no crash, no
# panic), pacman -U runs only for a release whose download verified, the
# installed version never goes down, the cache directory is left empty,
# and nothing is written outside the test directory.
. "$(dirname "$0")/../lib.sh"
upd="$BIN/raywm-update"
[ -x "$upd" ] || { echo "update: missing $upd"; exit 2; }
command -v openssl >/dev/null || { echo "update: openssl is required for the HTTPS server"; exit 2; }
seed=$STRESS_SEED
tmp_root="$STRESS_OUT/update-shared"; mkdir -p "$tmp_root"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp_root/key.pem" -out "$tmp_root/cert.pem" -days 2 \
    -subj /CN=127.0.0.1 -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1 || { echo "update: openssl failed"; exit 2; }

# world [specs...]: release fixtures served by a fresh HTTPS server.
world() {
    mkdir -p "$dir/etc/raywm" "$dir/home" "$dir/cache"
    echo '{}' >"$dir/plan.json"
    python3 "$stress_root/update/server.py" "$dir/w" "$tmp_root/cert.pem" "$tmp_root/key.pem" "$dir/plan.json" "$dir/port" >"$dir/server.log" 2>&1 &
    server_pid=$!
    mkdir -p "$dir/w"
    w=0; while [ ! -s "$dir/port" ]; do w=$((w + 1)); [ $w -gt 100 ] && { fail "HTTPS server did not start"; return 1; }; sleep 0.05; done
    port=$(cat "$dir/port")
    WORLD_BASE="https://127.0.0.1:$port" python3 "$root/tests/update/world.py" "$dir/w" "$@"
    api="https://127.0.0.1:$port/api/releases?per_page=100&page={page}"
}
world_end() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
plan() { printf '%s\n' "$1" >"$dir/plan.json"; }
# run [ulimit -f blocks] ARGS: raywm-update, bounded; status in $st, output in $dir/out.
run() {
    st=0
    fsize=${FSIZE:-unlimited}
    ( ulimit -f "$fsize"; env -i PATH="$PATH" HOME="$dir/home" USER=tester CURL_CA_BUNDLE="$tmp_root/cert.pem" \
        RAYWM_UPDATE_API="${API:-$api}" RAYWM_UPDATE_CONF="$dir/etc/raywm/update.conf" \
        RAYWM_UPDATE_PACMAN="$root/tests/update/fake-pacman.sh" RAYWM_UPDATE_SUDO= RAYWM_UPDATE_CACHE="$dir/cache" \
        FAKE_DB="$dir/db" FAKE_LOG="$dir/calls.log" timeout "${RUN_TIMEOUT:-120}" "$upd" "$@" ) >"$dir/out" 2>&1 </dev/null || st=$?
    case "$st" in 0|1|2) ;; 124) fail "raywm-update hung ($*)"; tail -3 "$dir/out" ;; *) fail "raywm-update exited $st ($*): $(tail -2 "$dir/out" | tr '\n' ' ')" ;; esac
    if grep -qE 'panic|reached unreachable|Segmentation|integer overflow|index out of bounds' "$dir/out"; then fail "crash: $(grep -m1 -E 'panic|unreachable|Segmentation|overflow|bounds' "$dir/out")"; fi
    if [ -n "$(ls -A "$dir/cache" 2>/dev/null)" ]; then fail "cache not cleaned: $(ls "$dir/cache")"; rm -rf "${dir:?}/cache/"*; fi
}
installed() { [ "$(cat "$dir/db" 2>/dev/null)" = "$1" ] || fail "installed '$(cat "$dir/db" 2>/dev/null)', expected '$1'"; }
no_install() { if grep -q '^pacman -U' "$dir/calls.log" 2>/dev/null; then fail "pacman -U ran"; fi; }
says() { grep -qE -- "$1" "$dir/out" || fail "output lacks /$1/: $(tail -2 "$dir/out" | tr '\n' ' ')"; }
setup_case() { case_begin "$1" "$seed"; echo "$2" >"$dir/db"; printf 'channel=%s\n' "$3" >"$dir/etc/raywm/update.conf" 2>/dev/null || { mkdir -p "$dir/etc/raywm"; printf 'channel=%s\n' "$3" >"$dir/etc/raywm/update.conf"; }; }
# reasset TAG FILE: replace a release's asset with FILE, metadata and listing updated to match.
reasset() {
    python3 - "$dir/w" "$1" "$2" <<'PY'
import hashlib, json, os, sys
w, tag, src = sys.argv[1:4]
data = open(src, "rb").read()
d = os.path.join(w, "dl", tag)
meta = json.load(open(os.path.join(d, "raywm-release.json")))
a = meta["assets"][0]
open(os.path.join(d, a["name"]), "wb").write(data)
a["size"], a["sha256"] = len(data), hashlib.sha256(data).hexdigest()
text = json.dumps(meta)
open(os.path.join(d, "raywm-release.json"), "w").write(text)
for page in sorted(f for f in os.listdir(os.path.join(w, "api")) if f.startswith("releases-")):
    p = os.path.join(w, "api", page)
    rel = json.load(open(p))
    for r in rel:
        for x in r.get("assets", []):
            if r.get("tag_name") == tag and x["name"] == a["name"]: x["size"] = len(data)
            if r.get("tag_name") == tag and x["name"] == "raywm-release.json": x["size"] = len(text)
    json.dump(rel, open(p, "w"))
PY
}

c_http_errors() {
    setup_case http-errors 0.2.1-1 beta
    world v0.2.2-beta || { case_end; return; }
    for s in 403 429; do
        plan "{\"/api/releases\": {\"status\": $s, \"headers\": {\"x-ratelimit-remaining\": \"0\"}, \"body\": \"{\\\"message\\\": \\\"API rate limit exceeded\\\"}\"}}"
        run --check; [ "$st" -eq 1 ] || fail "status $st on HTTP $s"; says "rate limit"
    done
    plan '{"/api/releases": {"status": 500}}'; run --check; [ "$st" -eq 1 ] || fail "status $st on 500"; says "server error"
    plan '{"/api/releases": {"status": 404}}'; run --check; [ "$st" -eq 1 ] || fail "status $st on 404"; says "404"
    plan '{"/dl/v0.2.2-beta/raywm-release.json": {"status": 503}}'; run --check; says "trying an older release"
    plan '{"/dl/v0.2.2-beta/raywm-v0.2.2-beta.tar.gz": {"status": 403}}'; run --install --yes; [ "$st" -eq 1 ] || fail "asset 403: status $st"; no_install
    installed 0.2.1-1; world_end; case_end
}

c_redirects() {
    setup_case redirects 0.2.1-1 beta
    world v0.2.2-beta || { case_end; return; }
    plan "{\"/dl/v0.2.2-beta/raywm-v0.2.2-beta.tar.gz\": {\"redirect\": \"http://127.0.0.1:$port/dl/v0.2.2-beta/raywm-v0.2.2-beta.tar.gz\"}}"
    run --install --yes; [ "$st" -eq 1 ] || fail "redirect to http accepted (status $st)"; no_install
    plan "{\"/api/releases\": {\"redirect\": \"http://127.0.0.1:$port/api/releases?page=1\"}}"
    run --check; [ "$st" -eq 1 ] || fail "API redirect to http accepted"
    plan "{\"/dl/v0.2.2-beta/raywm-release.json\": {\"redirect\": \"https://127.0.0.1:$port/dl/v0.2.2-beta/raywm-release.json\"}}"
    run --check; [ "$st" -ne 0 ] || grep -q 'trying an older' "$dir/out" || note "redirect loop handled: $(tail -1 "$dir/out")"
    installed 0.2.1-1; world_end; case_end
}

c_truncated() {
    setup_case truncated 0.2.1-1 stable
    world v0.2.2-stable || { case_end; return; }
    plan '{"/dl/v0.2.2-stable/raywm-0.2.2-1-x86_64.pkg.tar.zst": {"truncate": 40}}'
    run --install --yes; [ "$st" -eq 1 ] || fail "truncated download: status $st"; no_install
    plan '{"/dl/v0.2.2-stable/raywm-0.2.2-1-x86_64.pkg.tar.zst": {"chunked_extra": 100000}}'
    run --install --yes; [ "$st" -eq 1 ] || fail "oversized download: status $st"; no_install
    plan '{"/dl/v0.2.2-stable/raywm-release.json": {"truncate": 30}}'
    run --check; [ "$st" -eq 2 ] || fail "truncated metadata: status $st (expected up to date)"
    plan '{"/dl/v0.2.2-stable/raywm-0.2.2-1-x86_64.pkg.tar.zst": {"slow": 400}}'
    run --install --yes; [ "$st" -eq 0 ] || fail "slow but complete download failed ($st)"
    installed 0.2.2-1; world_end; case_end
}

c_endless() {
    setup_case endless 0.2.1-1 beta
    world v0.2.2-beta || { case_end; return; }
    plan '{"/api/releases": {"endless": true}}'
    t0=$(now_ms); run --check; [ "$st" -eq 1 ] || fail "endless API: status $st"
    note "endless API refused after $(( ($(now_ms) - t0) / 1000 )) s"
    plan '{"/dl/v0.2.2-beta/raywm-release.json": {"endless": true}}'; run --check; [ "$st" -eq 2 ] || fail "endless metadata: status $st"
    plan '{"/dl/v0.2.2-beta/raywm-v0.2.2-beta.tar.gz": {"endless": true}}'; run --install --yes; [ "$st" -eq 1 ] || fail "endless asset: status $st"; no_install
    world_end; case_end
}

c_stall() {
    setup_case stall 0.2.1-1 beta
    world v0.2.2-beta || { case_end; return; }
    plan '{"/api/releases": {"hang": 600}}'
    t0=$(now_ms); RUN_TIMEOUT=240 run --check; dt=$(( ($(now_ms) - t0) / 1000 ))
    note "stalled API: raywm-update gave up after $dt s (status $st)"
    [ "$st" -eq 1 ] || fail "stalled API: status $st after $dt s"
    # The stalled asset takes another ~100 s: STRESS and SOAK only.
    [ "$STRESS_LEVEL" = fast ] && { world_end; case_end; return; }
    plan '{"/dl/v0.2.2-beta/raywm-v0.2.2-beta.tar.gz": {"hang": 600}}'
    t0=$(now_ms); RUN_TIMEOUT=240 run --install --yes; dt=$(( ($(now_ms) - t0) / 1000 ))
    note "stalled download: gave up after $dt s (status $st)"
    [ "$st" -eq 1 ] || fail "stalled download: status $st after $dt s"; no_install
    world_end; case_end
}

c_disk_full() {
    setup_case disk-full 0.2.1-1 stable
    world v0.2.2-stable || { case_end; return; }
    head -c 3000000 /dev/urandom >"$dir/big"; reasset v0.2.2-stable "$dir/big"
    FSIZE=512 run --install --yes   # 512 KiB per file
    [ "$st" -eq 1 ] || fail "download over the file-size limit: status $st"; no_install
    chmod 500 "$dir/cache"; run --install --yes; chmod 700 "$dir/cache"
    [ "$st" -eq 1 ] || fail "unwritable cache: status $st"; no_install
    installed 0.2.1-1; world_end; case_end
}

c_traversal() {
    setup_case traversal 0.2.1beta.2-1 beta
    world v0.2.2-beta || { case_end; return; }
    mkdir -p "$dir/outside"
    for kind in dotdot absolute symlink-dir symlink-abs hardlink device; do
        python3 - "$dir/evil-$kind.tar.gz" "$kind" "$dir/outside" <<'PY'
import io, sys, tarfile
out, kind, outside = sys.argv[1:4]
top = "raywm-v0.2.2-beta/"
with tarfile.open(out, "w:gz") as t:
    def add(name, data=b"x", **kw):
        i = tarfile.TarInfo(name); i.size = len(data); [setattr(i, k, v) for k, v in kw.items()]
        t.addfile(i, io.BytesIO(data))
    script = b"#!/bin/sh\necho built-from-evil >>\"$FAKE_LOG\"\nexit 1\n"
    add(top + "scripts/arch-package.sh", script, mode=0o755)
    if kind == "dotdot": add(top + "../../outside/dotdot-escape")
    if kind == "absolute": add(outside + "/absolute-escape")
    if kind == "symlink-dir":
        i = tarfile.TarInfo(top + "link"); i.type = tarfile.SYMTYPE; i.linkname = outside; t.addfile(i)
        add(top + "link/symlink-escape")
    if kind == "symlink-abs":
        i = tarfile.TarInfo(top + "passwd"); i.type = tarfile.SYMTYPE; i.linkname = "/etc/passwd"; t.addfile(i)
    if kind == "hardlink":
        i = tarfile.TarInfo(top + "hard"); i.type = tarfile.LNKTYPE; i.linkname = outside + "/target"; t.addfile(i)
    if kind == "device":
        i = tarfile.TarInfo(top + "null"); i.type = tarfile.CHRTYPE; i.devmajor, i.devminor = 1, 3; t.addfile(i)
PY
        echo secret >"$dir/outside/target"
        reasset v0.2.2-beta "$dir/evil-$kind.tar.gz"
        : >"$dir/calls.log"
        run --install --yes
        [ "$st" -eq 1 ] || fail "$kind archive: status $st"
        no_install
        if ls "$dir/outside" | grep -q escape; then fail "$kind archive wrote outside the work directory: $(ls "$dir/outside")"; fi
        [ "$(cat "$dir/outside/target")" = secret ] || fail "$kind archive changed a file outside"
        if grep -q built-from-evil "$dir/calls.log"; then fail "$kind: the archive was accepted and its build script ran"; fi
        grep -q 'unexpected\|cannot extract\|contains a link' "$dir/out" && note "$kind: $(grep -m1 -E 'unexpected|cannot extract|contains a link' "$dir/out" | cut -c1-120)"
    done
    installed 0.2.1beta.2-1; world_end; case_end
}

c_metadata_fuzz() {
    n=$(level_pick 60 400 1500)
    setup_case metadata-fuzz 0.2.1-1 beta
    world v0.2.2-beta v0.2.2-stable || { case_end; return; }
    cp -r "$dir/w/dl" "$dir/dl.orig"; cp -r "$dir/w/api" "$dir/api.orig"
    i=0; installs=0
    while [ $i -lt "$n" ]; do
        rm -rf "$dir/w/dl" "$dir/w/api"; cp -r "$dir/dl.orig" "$dir/w/dl"; cp -r "$dir/api.orig" "$dir/w/api"
        python3 - "$dir/w" "$((seed * 100000 + i))" >"$dir/mutation" <<'PY'
import json, os, random, sys
w, seed = sys.argv[1], int(sys.argv[2])
r = random.Random(seed)
targets = [os.path.join(w, "api", "releases-1.json")] + [os.path.join(w, "dl", t, "raywm-release.json") for t in ("v0.2.2-beta", "v0.2.2-stable")]
path = r.choice(targets)
text = open(path).read()
values = [None, True, 0, -1, 2**63, 1e308, "", "x" * 10000, "../../etc/passwd", [], {}, "v0.2.2-beta", "0.2.2-1",
          "\u0000", "日本", "a" * 64, "f" * 64, [1, 2], {"a": {"b": {"c": []}}}]
def mutate(o, depth=0):
    if isinstance(o, dict) and o:
        k = r.choice(list(o))
        if r.random() < 0.3: o[k] = r.choice(values)
        elif r.random() < 0.15: del o[k]
        else: mutate(o[k], depth + 1)
    elif isinstance(o, list) and o:
        i = r.randrange(len(o))
        if r.random() < 0.3: o[i] = r.choice(values)
        elif r.random() < 0.1: o.append(r.choice(values))
        else: mutate(o[i], depth + 1)
mode = r.randrange(4)
if mode == 0:
    text = text[: r.randrange(len(text))]                          # truncated
elif mode == 1:
    b = bytearray(text.encode()); b[r.randrange(len(b))] = r.randrange(256); text = b.decode("latin-1")
elif mode == 2:
    o = json.loads(text)
    for _ in range(r.randrange(1, 4)): mutate(o)
    text = json.dumps(o)
else:
    text = "[" * r.randrange(1, 5000)                             # deep nesting
open(path, "w", encoding="latin-1" if mode == 1 else "utf-8").write(text)
print(os.path.relpath(path, w), mode)
PY
        : >"$dir/calls.log"; echo 0.2.1-1 >"$dir/db"
        run --install --yes
        if grep -q '^pacman -U' "$dir/calls.log"; then
            installs=$((installs + 1))
            # Only a release whose package verified may be installed: the fake
            # pacman reads the version from the verified package itself.
            v=$(cat "$dir/db")
            case "$v" in 0.2.2-1|0.2.2beta-1) ;; *) fail "mutation $(cat "$dir/mutation") installed '$v'" ;; esac
        fi
        i=$((i + 1))
    done
    note "$n mutations: $installs still installed a verified release, the rest were refused"
    world_end; case_end
}

c_channel_file() {
    setup_case channel-file 0.2.2beta-1 beta
    world v0.2.2-stable || { case_end; return; }
    conf="$dir/etc/raywm/update.conf"
    echo 'channel=beta' >"$dir/elsewhere"
    rm -f "$conf"; ln -s "$dir/elsewhere" "$conf"
    run --set-channel stable; [ "$st" -eq 0 ] || fail "set-channel over a symlink: $st"
    [ "$(cat "$dir/elsewhere")" = channel=beta ] || fail "set-channel wrote through the symlink"
    [ -L "$conf" ] && fail "the symlink was kept"
    head -c 100000 /dev/zero | tr '\0' '#' >"$conf"; run --check; [ "$st" -eq 1 ] || fail "huge update.conf: status $st"
    head -c 300 /dev/urandom >"$conf"; run --check; [ "$st" -eq 1 ] || fail "binary update.conf: status $st"
    rm -f "$conf"; mkdir "$conf"; run --check; [ "$st" -eq 1 ] || fail "directory update.conf: status $st"; rmdir "$conf"
    printf 'channel=stable\0channel=beta\n' >"$conf"; run --check; [ "$st" -eq 1 ] || fail "NUL in update.conf: status $st"
    no_install; world_end; case_end
}

c_downgrade() {
    setup_case downgrade 0.3.0-1 beta
    world v0.2.1-beta v0.2.2-beta v0.2.2-stable v0.2.9-beta.7 || { case_end; return; }
    run --install --yes; [ "$st" -eq 0 ] || fail "status $st"; says "nothing to install"; no_install; installed 0.3.0-1
    echo 0.2.2-1 >"$dir/db"; run --install --yes; installed 0.2.9beta.7-1
    # Metadata claiming a far newer version for an older tag is ignored.
    python3 - "$dir/w/dl/v0.2.9-beta.7/raywm-release.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["pacman_version"] = "9.9.9-1"; m["pkgver"] = "9.9.9"; json.dump(m, open(sys.argv[1], "w"))
PY
    echo 0.2.2-1 >"$dir/db"; : >"$dir/calls.log"; run --install --yes; no_install; installed 0.2.2-1
    world_end; case_end
}

c_pagination() {
    setup_case pagination 0.2.1-1 beta
    world v0.2.2-beta || { case_end; return; }
    python3 - "$dir/w/api" <<'PY'
import json, os, sys
filler = [dict(tag_name="v0.0.%d" % i, draft=False, prerelease=False, assets=[]) for i in range(100)]
for p in range(1, 30): json.dump(filler, open(os.path.join(sys.argv[1], "releases-%d.json" % p), "w"))
PY
    t0=$(now_ms); run --check
    n=$(grep -c 'GET /api/releases' "$dir/w/requests.log" || true)
    note "endless pagination: $n pages requested in $(( ($(now_ms) - t0) / 1000 )) s, status $st"
    [ "$n" -le 10 ] || fail "requested $n API pages (limit 10)"
    [ "$st" -eq 2 ] || fail "status $st"
    world_end; case_end
}

c_deep_json() {
    setup_case deep-json 0.2.1-1 beta
    mkdir -p "$dir/api" "$dir/cache" "$dir/home"
    for n in 100000 5000000; do
        python3 -c "import sys; sys.stdout.write('[' * $n)" >"$dir/api/releases-1.json"
        API="file://$dir/api/releases-{page}.json" run --check; [ "$st" -eq 1 ] || fail "unclosed nesting $n: status $st"
        python3 -c "import sys; sys.stdout.write('[' * $n + ']' * $n)" >"$dir/api/releases-1.json"
        API="file://$dir/api/releases-{page}.json" run --check; [ "$st" -eq 2 ] || fail "closed nesting $n: status $st"
    done
    case_end
}

for c in deep-json http-errors redirects truncated endless stall disk-full traversal metadata-fuzz channel-file downgrade pagination; do
    want_case "$c" && "c_$(echo "$c" | tr - _)"
done
summary

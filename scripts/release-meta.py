#!/usr/bin/env python3
"""Release tag rules and update-channel metadata (standard library only).

  release-meta.py parse TAG
      Prints JSON {tag, channel, version, prerelease, pkgver, pacman_version}
      or exits 1 for a tag outside the release scheme.
  release-meta.py metadata TAG COMMIT OUT.json ASSET...
      Writes raywm-release.json for the raywm-update channel system.
  release-meta.py check-zon TAG build.zig.zon
      Exits 1 unless build.zig.zon's version equals the tag's version.
  release-meta.py notes TAG CHANGELOG.md
      Prints the CHANGELOG section "## [vX.Y.Z]..." for the tag's version;
      exits 1 when there is none (every release needs a CHANGELOG entry).

Tags: vX.Y.Z-beta, vX.Y.Z-beta.N (N >= 2), vX.Y.Z-stable. The pacman
version maps beta to "X.Y.Zbeta[.N]" and stable to "X.Y.Z", so that
vercmp orders 0.2.1beta < 0.2.1beta.2 < 0.2.1 < 0.2.2beta (see
docs/RELEASE-WORKFLOW.md). Historical tags (v0.1.0 ... v0.2.1) predate the
scheme and are reported as channel "legacy".
"""
import hashlib
import json
import os
import re
import sys

TAG = re.compile(r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-(beta(?:\.([2-9]|[1-9]\d+))?|stable)$')
LEGACY = re.compile(r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')
SCHEMA = 1


def parse(tag):
    m = TAG.match(tag)
    if not m:
        if LEGACY.match(tag):
            v = tag[1:]
            return dict(tag=tag, channel='legacy', version=v, prerelease=None, pkgver=v, pacman_version=v + '-1')
        return None
    version = '.'.join(m.group(1, 2, 3))
    if m.group(4) == 'stable':
        channel, pre, pkgver = 'stable', None, version
    else:
        channel = 'beta'
        pre = int(m.group(5)) if m.group(5) else 1
        pkgver = version + 'beta' + (f'.{pre}' if m.group(5) else '')
    return dict(tag=tag, channel=channel, version=version, prerelease=pre,
                pkgver=pkgver, pacman_version=pkgver + '-1')


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main(argv):
    if len(argv) >= 2 and argv[0] == 'parse':
        info = parse(argv[1])
        if not info:
            print(f'not a release tag: {argv[1]}', file=sys.stderr)
            return 1
        print(json.dumps(info))
        return 0
    if len(argv) == 3 and argv[0] == 'check-zon':
        info = parse(argv[1])
        zon = open(argv[2], encoding='utf-8').read()
        m = re.search(r'\.version\s*=\s*"([^"]+)"', zon)
        if not info or not m or m.group(1) != info['version']:
            print(f'version mismatch: tag {argv[1]}, build.zig.zon {m.group(1) if m else None}', file=sys.stderr)
            return 1
        return 0
    if len(argv) == 3 and argv[0] == 'notes':
        info = parse(argv[1])
        if not info:
            return 1
        text = open(argv[2], encoding='utf-8').read()
        m = re.search(r'^## \[v' + re.escape(info['version']) + r'\][^\n]*\n(.*?)(?=^## \[|\Z)', text, re.S | re.M)
        if not m or not m.group(1).strip():
            print(f'CHANGELOG.md has no section for v{info["version"]}', file=sys.stderr)
            return 1
        print(m.group(1).strip())
        return 0
    if len(argv) >= 4 and argv[0] == 'metadata':
        tag, commit, out, assets = argv[1], argv[2], argv[3], argv[4:]
        info = parse(tag)
        if not info or info['channel'] == 'legacy':
            print(f'not a release tag: {tag}', file=sys.stderr)
            return 1
        kinds = {'.pkg.tar.zst': 'arch-package', '.tar.gz': 'source'}
        entries = []
        for path in assets:
            name = os.path.basename(path)
            kind = next((k for suffix, k in kinds.items() if name.endswith(suffix)), 'other')
            entries.append(dict(name=name, kind=kind, size=os.path.getsize(path), sha256=sha256(path)))
        meta = dict(
            schema=SCHEMA,
            project='raywm',
            tag=tag,
            commit=commit,
            channel=info['channel'],
            # Channels that offer this release: beta subscribers also get
            # stable releases; stable subscribers never get betas.
            channels=['beta', 'stable'] if info['channel'] == 'stable' else ['beta'],
            version=info['version'],
            prerelease=info['prerelease'],
            pkgver=info['pkgver'],
            pacman_version=info['pacman_version'],
            compare='vercmp(pacman_version)',
            assets=entries,
        )
        with open(out, 'w', encoding='utf-8') as f:
            json.dump(meta, f, indent=2)
            f.write('\n')
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

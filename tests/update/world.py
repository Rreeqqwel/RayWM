#!/usr/bin/env python3
"""Builds a fake GitHub release world for tests/update.sh (stdlib only).

  world.py DIR SPEC...

Each SPEC is TAG[:flag,flag...]. Flags:
  corrupt       the asset's bytes differ from the sha256 in the metadata
  noasset       the main asset is not attached to the release
  nometa        raywm-release.json is not attached
  badmeta       raywm-release.json is not valid JSON
  wrongmeta     raywm-release.json names another pacman_version
  gone          the asset is listed but missing on the "server" (404)
  badflag       the GitHub Pre-release flag contradicts the tag
  evilpkg       the Stable package installs /etc/raywm/update.conf
  legacy        a historical release without metadata (e.g. v0.2.1)
  draft         an unpublished draft
  symlink       the Beta source archive contains a symlink (to /etc/passwd)

Writes DIR/api/releases-1.json (and -2.json with PAGE2=1 in the
environment: page 1 then holds 100 historical entries first), and every
file under DIR/dl/TAG/. Beta assets are tar.gz source archives whose
scripts/arch-package.sh is a stand-in for makepkg (tests/update/fake-build.sh);
Stable assets and built packages are text "packages" read by
tests/update/fake-pacman.sh.
"""
import hashlib
import io
import json
import os
import re
import sys
import tarfile

TAG = re.compile(r'^v(\d+)\.(\d+)\.(\d+)-(beta(?:\.(\d+))?|stable)$')
HERE = os.path.dirname(os.path.abspath(__file__))


def pkgver(tag):
    m = TAG.match(tag)
    v = '.'.join(m.group(1, 2, 3))
    if m.group(4) == 'stable':
        return 'stable', v
    return 'beta', v + 'beta' + (f'.{m.group(5)}' if m.group(5) else '')


def fake_package(version, evil=False):
    files = ['/usr/', '/usr/bin/', '/usr/bin/raywm', '/usr/bin/raywmctl', '/usr/bin/raywm-update',
             '/usr/share/', '/usr/share/raywm/', '/usr/share/raywm/config/raywm.conf']
    if evil:
        files.append('/etc/raywm/update.conf')
    return ('Name            : raywm\nVersion         : %s\nArchitecture    : x86_64\n--files\n' % version
            + ''.join('raywm %s\n' % f for f in files)).encode()


def source_archive(tag, symlink=False):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as t:
        script = open(os.path.join(HERE, 'fake-build.sh'), 'rb').read()
        info = tarfile.TarInfo(f'raywm-{tag}/scripts/arch-package.sh')
        info.size, info.mode = len(script), 0o755
        t.addfile(info, io.BytesIO(script))
        readme = b'fake RayWM source for tests/update.sh\n'
        info = tarfile.TarInfo(f'raywm-{tag}/README.md')
        info.size = len(readme)
        t.addfile(info, io.BytesIO(readme))
        if symlink:
            info = tarfile.TarInfo(f'raywm-{tag}/passwd')
            info.type, info.linkname = tarfile.SYMTYPE, '/etc/passwd'
            t.addfile(info)
    return buf.getvalue()


def main(out, specs):
    # WORLD_BASE: serve the same tree over HTTPS (tests/stress/update).
    base = os.environ.get('WORLD_BASE') or 'file://' + os.path.abspath(out)
    releases = []
    for spec in specs:
        tag, _, flags = spec.partition(':')
        flags = set(filter(None, flags.split(',')))
        d = os.path.join(out, 'dl', tag)
        os.makedirs(d, exist_ok=True)
        url = lambda name: f'{base}/dl/{tag}/{name}'
        if 'legacy' in flags or not TAG.match(tag):
            releases.append(dict(tag_name=tag, draft=False, prerelease=False, assets=[]))
            continue
        channel, pv = pkgver(tag)
        if channel == 'beta':
            name, kind, data = f'raywm-{tag}.tar.gz', 'source', source_archive(tag, 'symlink' in flags)
        else:
            name, kind, data = f'raywm-{pv}-1-x86_64.pkg.tar.zst', 'arch-package', fake_package(pv + '-1', 'evilpkg' in flags)
        sha = hashlib.sha256(data).hexdigest()
        if 'corrupt' in flags:
            data = data[:-1] + bytes([data[-1] ^ 1])
        if 'gone' not in flags:
            open(os.path.join(d, name), 'wb').write(data)
        version = '.'.join(TAG.match(tag).group(1, 2, 3))
        meta = dict(schema=1, project='raywm', tag=tag, commit='0' * 40, channel=channel,
                    channels=['beta', 'stable'] if channel == 'stable' else ['beta'], version=version,
                    prerelease=None if channel == 'stable' else 1, pkgver=pv,
                    pacman_version=('9.9.9' if 'wrongmeta' in flags else pv) + '-1',
                    compare='vercmp(pacman_version)',
                    assets=[dict(name=name, kind=kind, size=len(data), sha256=sha)])
        text = '{"schema": 1, "tag": ' if 'badmeta' in flags else json.dumps(meta, indent=2)
        open(os.path.join(d, 'raywm-release.json'), 'w').write(text)
        assets = []
        if 'noasset' not in flags:
            assets.append(dict(name=name, size=len(data), browser_download_url=url(name)))
        if 'nometa' not in flags:
            assets.append(dict(name='raywm-release.json', size=len(text), browser_download_url=url('raywm-release.json')))
        pre = channel == 'beta'
        if 'badflag' in flags:
            pre = not pre
        releases.append(dict(tag_name=tag, draft='draft' in flags, prerelease=pre, assets=assets))
    api = os.path.join(out, 'api')
    os.makedirs(api, exist_ok=True)
    if os.environ.get('PAGE2'):
        filler = [dict(tag_name=f'v0.0.{i}', draft=False, prerelease=False, assets=[]) for i in range(100)]
        json.dump(filler, open(os.path.join(api, 'releases-1.json'), 'w'))
        json.dump(releases, open(os.path.join(api, 'releases-2.json'), 'w'))
    else:
        json.dump(releases, open(os.path.join(api, 'releases-1.json'), 'w'))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2:])

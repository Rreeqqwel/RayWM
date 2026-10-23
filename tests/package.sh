#!/bin/sh
# Extract and install an archive only into disposable /tmp directories.
set -eu
archive=${1:?usage: tests/package.sh ARCHIVE}
python3 - "$archive" <<'PY'
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

archive = Path(sys.argv[1]).resolve()
checks = 0

def check(ok):
    global checks
    assert ok
    checks += 1

with tempfile.TemporaryDirectory(prefix='raywm-package-test-') as temp:
    work = Path(temp)
    with tarfile.open(archive) as source:
        members = source.getmembers()
        for entry in members:
            check(entry.isfile() or entry.isdir())
            check(not Path(entry.name).is_absolute() and '..' not in Path(entry.name).parts)
            check(entry.uid == 0 and entry.gid == 0)
        check(len({entry.mtime for entry in members}) == 1)
        check(len({Path(entry.name).parts[0] for entry in members}) == 1)
        source.extractall(work, filter='data')
    stage = next(work.iterdir())
    commit = subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    check((stage/'COMMIT').read_text().strip() == commit)
    check('test_input=false' in (stage/'BUILD-INFO').read_text())
    subprocess.run(['sha256sum','-c','MANIFEST.sha256'],cwd=stage,check=True,stdout=subprocess.DEVNULL)
    binary = (stage/'bin/raywm').read_bytes()
    check(b'wlr_virtual_pointer_manager_v1_create' not in binary and b'raywm-test-unplug' not in binary and b'TEST BUILD: virtual pointer' not in binary)
    check(not any('raywm-test-' in entry.name or 'recovery/' in entry.name or '.claude/' in entry.name for entry in members))
    check(os.access(stage/'bin/raywm',os.X_OK) and os.access(stage/'bin/raywmctl',os.X_OK))
    subprocess.run([stage/'bin/raywm','-h'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    prefix, config = work/'prefix with spaces', work/'config with spaces'
    command = [str(stage/'install.sh'),'--prefix',str(prefix),'--config-dir',str(config)]
    def install(extra=(), expected=0):
        result = subprocess.run(command+list(extra),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        assert result.returncode == expected, result.stdout
    install()
    check((config/'plugins/animations.lua').exists() and (prefix/'bin/raywmctl').exists())
    (config/'keep-me').write_text('local config\n')
    digest = hashlib.sha256((prefix/'bin/raywm').read_bytes()).hexdigest()
    install(expected=1)
    check(hashlib.sha256((prefix/'bin/raywm').read_bytes()).hexdigest() == digest)
    (prefix/'bin/raywm').write_text('old binary\n')
    (prefix/'bin/raywmctl').write_text('old client\n')
    install(['--force'])
    check((prefix/'bin/raywm.bak').read_text() == 'old binary\n')
    check((prefix/'bin/raywmctl.bak').read_text() == 'old client\n')
    install(['--force'])
    check((prefix/'bin/raywm.bak.1').exists() and (prefix/'bin/raywm.bak').read_text() == 'old binary\n')
    check((config/'keep-me').read_text() == 'local config\n')
    # Preflight refuses a symlink without modifying its target or the other binary.
    (prefix/'bin/raywmctl').unlink()
    sentinel = work/'sentinel'; sentinel.write_text('keep\n')
    (prefix/'bin/raywmctl').symlink_to(sentinel)
    digest = hashlib.sha256((prefix/'bin/raywm').read_bytes()).hexdigest()
    install(['--force'],expected=1)
    check(sentinel.read_text() == 'keep\n' and hashlib.sha256((prefix/'bin/raywm').read_bytes()).hexdigest() == digest)
    for option in ['--prefix','--config-dir']:
        check(subprocess.run([stage/'install.sh',option],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 2)
print(f'package: {checks} archive/installer checks passed')
PY

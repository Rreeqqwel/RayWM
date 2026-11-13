#!/bin/sh
# Exercise packaging control flow without installing Zig or building RayWM.
set -eu
python3 - "$(dirname "$0")/.." <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = Path(sys.argv[1]).resolve()

def run(args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)

with tempfile.TemporaryDirectory(prefix='raywm-archive-errors-') as temp:
    work = Path(temp)
    repo, tools = work / 'repo', work / 'tools'
    tools.mkdir()
    run(['git', 'clone', '--quiet', '--no-hardlinks', str(root), str(repo)])
    # Include the scripts under test even before their changes are committed.
    for name in ('source-archive.sh', 'package.sh'):
        shutil.copyfile(root / 'scripts' / name, repo / 'scripts' / name)
    run(['git', '-c', 'user.name=Archive tests', '-c', 'user.email=tests@example.invalid',
         'commit', '--quiet', '--allow-empty', '-am', 'Packaging fixture'], cwd=repo)
    # Read the version from the fixture instead of depending on a release number.
    import re
    version = re.search(r'\.version\s*=\s*"([^"]+)"', (repo / 'build.zig.zon').read_text())[1]

    def tool(name, body):
        path = tools / name
        path.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
        path.chmod(0o755)

    tool('zig', '''if [ "$1" = version ]; then echo 0.16.0; exit; fi
if [ "$2" = --fetch ]; then mkdir -p zig-pkg; exit; fi
while [ "$1" != -p ]; do shift; done
mkdir -p "$2/bin"
printf '#!/bin/sh\\nexit 0\\n' >"$2/bin/raywm"
chmod +x "$2/bin/raywm"''')
    for name in ('tar', 'gzip'):
        real = shutil.which(name)
        condition = '[ "${FAIL_TOOL:-}" = gzip ]' if name == 'gzip' else '[ "${FAIL_TOOL:-}" = tar ] && [ "${1:-}" = --sort=name ]'
        tool(name, f'if {condition}; then echo "injected {name} failure" >&2; exit 42; fi\nexec "{real}" "$@"')
    real_sha256sum = shutil.which('sha256sum')
    tool('sha256sum', f'''if [ "${{FAIL_TOOL:-}}" = sha256sum ]; then echo "injected sha256sum failure" >&2; exit 42; fi
exec "{real_sha256sum}" "$@"''')
    tool('nm', ':')
    tool('strings', ':')
    tool('strip', 'if [ "$1" = --version ]; then echo "test strip"; fi')
    tool('pkg-config', 'echo 1.0')
    env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'], ZIG=str(tools / 'zig'))
    checks = 0
    for script in ('source-archive.sh', 'package.sh'):
        for failure in (('tar', 'gzip', 'sha256sum', '') if script == 'source-archive.sh'
                        else ('tar', 'gzip', '')):
            out = work / (script + '-' + (failure or 'success'))
            case_env = dict(env, FAIL_TOOL=failure, RAYWM_DIST_DIR=str(out))
            if script == 'source-archive.sh':
                tag = 'v' + version + '-beta'
                args = ['sh', 'scripts/' + script, tag, str(out), 'HEAD']
                archive = out / ('raywm-' + tag + '.tar.gz')
            else:
                args = ['sh', 'scripts/' + script, 'v' + version]
                archive = out / ('raywm-v' + version + '-linux-x86_64.tar.gz')
            result = subprocess.run(args, cwd=repo, env=case_env, capture_output=True, text=True)
            if failure:
                assert result.returncode != 0, (script, failure, result.stdout, result.stderr)
                assert 'injected ' + failure + ' failure' in result.stderr, result.stderr
                assert not archive.exists(), archive
                assert not Path(str(archive) + '.sha256').exists(), archive
            else:
                assert result.returncode == 0, (script, result.stdout, result.stderr)
                with tarfile.open(archive) as payload:
                    assert any(m.name.endswith('/build.zig') if script == 'source-archive.sh'
                               else m.name.endswith('/bin/raywm') for m in payload.getmembers())
                run(['sha256sum', '-c', archive.name + '.sha256'], cwd=out)
            checks += 1
    print(f'archive-errors: {checks} packaging scenarios passed (build tools mocked)')
PY

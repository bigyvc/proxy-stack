#!/usr/bin/env python3
"""Offline bootstrap regression: fresh clone and switching an existing origin.

Only the install directory and root guard are adapted for the temporary sandbox.
The fixture's install.sh records success instead of changing system services.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'bootstrap.sh').read_text()
RAW = 'https://raw.githubusercontent.com/bigyvc/proxy-stack/main/bootstrap.sh'
assert 'PSM_REPO="${PSM_REPO:-https://github.com/bigyvc/proxy-stack.git}"' in SCRIPT
assert '${PSM_BOOTSTRAP_URL:-' + RAW + '}' in SCRIPT
assert 'github.com/bigyvc/proxy-stack/releases/download/' in (ROOT / 'lib/agent.sh').read_text()
for p in ROOT.glob('README*.md'):
    s = p.read_text()
    assert RAW in s, p
    assert 'https://psm.jinqians.com' not in s, p

def git(*args):
    return subprocess.check_output(['git', *map(str, args)], text=True, stderr=subprocess.PIPE).strip()

with tempfile.TemporaryDirectory(prefix='psm-fork-') as temp:
    base = Path(temp)
    seed = base / 'seed'
    git('init', '-b', 'main', seed)
    git('-C', seed, 'config', 'user.name', 'PSM fixture')
    git('-C', seed, 'config', 'user.email', 'fixture@example.invalid')
    (seed / 'install.sh').write_text('#!/usr/bin/env bash\nprintf installed > "$(dirname "$0")/installed.marker"\n')
    (seed / 'manager.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
    (seed / 'lib').mkdir()
    (seed / 'lib/common.sh').write_text('# fixture\n')
    git('-C', seed, 'add', '.')
    git('-C', seed, 'commit', '-qm', 'fixture')
    remote = base / 'fork.git'
    old_remote = base / 'upstream.git'
    git('clone', '--bare', seed, remote)
    git('clone', '--bare', seed, old_remote)
    git('-C', remote, 'config', 'uploadpack.allowFilter', 'true')

    def run(target, expected_rc=0, via_sh=False):
        script = base / 'bootstrap-test.sh'
        adapted = SCRIPT.replace('PSM_DIR="/opt/psm"', 'PSM_DIR="' + str(target) + '"')
        adapted = '\n'.join(line for line in adapted.split('\n') if not line.startswith('[[ $EUID -eq 0 ]]'))
        script.write_text(adapted)
        env = dict(os.environ, PSM_REPO=remote.as_uri(), PSM_BRANCH='main', PSM_LANG='en')
        if via_sh:
            tools = base / 'mock-tools'
            tools.mkdir(exist_ok=True)
            curl = tools / 'curl'
            curl.write_text('''#!/usr/bin/env bash
set -eu
while (( $# )); do
    case "$1" in
        https://*) printf '%s' "$1" > "$PSM_MOCK_URL" ;;
        -o) cp "$PSM_MOCK_SCRIPT" "$2"; shift ;;
    esac
    shift
done
''')
            curl.chmod(0o755)
            env.update(PATH=str(tools) + ':' + env['PATH'], PSM_MOCK_SCRIPT=str(script), PSM_MOCK_URL=str(base / 'shim-url'))
            result = subprocess.run(['sh'], input=adapted, env=env, text=True, capture_output=True)
            assert (base / 'shim-url').read_text() == RAW
        else:
            result = subprocess.run(['bash', str(script)], env=env, text=True, capture_output=True)
        assert result.returncode == expected_rc, result.stdout + result.stderr

    fresh = base / 'fresh'
    run(fresh)
    assert (fresh / 'installed.marker').read_text() == 'installed'
    assert git('-C', fresh, 'remote', 'get-url', 'origin') == remote.as_uri()
    print('ok: fresh bootstrap uses requested fork and invokes installer')

    shim = base / 'sh-install'
    run(shim, via_sh=True)
    assert (shim / 'installed.marker').read_text() == 'installed'
    print('ok: POSIX sh shim re-downloads this fork bootstrap, then installs')

    existing = base / 'existing'
    git('clone', '-b', 'main', old_remote.as_uri(), existing)
    (seed / 'fork.marker').write_text('fork revision\n')
    git('-C', seed, 'add', '.')
    git('-C', seed, 'commit', '-qm', 'fork update')
    git('-C', seed, 'push', remote, 'main')
    run(existing)
    assert git('-C', existing, 'remote', 'get-url', 'origin') == remote.as_uri()
    assert git('-C', existing, 'config', 'branch.main.remote') == 'origin'
    assert git('-C', existing, 'config', 'branch.main.merge') == 'refs/heads/main'
    assert (existing / 'fork.marker').read_text() == 'fork revision\n'
    print('ok: existing bootstrap switches origin and pulls the fork revision')

    git('-C', existing, 'checkout', '--detach')
    run(existing, expected_rc=1)
    print('ok: detached HEAD rejected before update reset')

print('fork source checks passed')

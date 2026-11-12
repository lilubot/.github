#!/usr/bin/env bash
# Exercise embedded scripts without a live token, runner, or package installation.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


def step(file, name):
    text = Path('.github/workflows/' + file + '.yml').read_text()
    block = text.split('      - name: ' + name + '\n', 1)[1]
    block = block.split('\n      - ', 1)[0]
    return textwrap.dedent(block.split('        run: |', 1)[1].split('\n', 1)[1])


# Execute the actual merge-conflict script, including its HTTP serialization.
source = step('pr-hygiene', 'Publish merge-conflict status on live PR heads')
sha = 'a' * 40
# Run the actual bash consumer with configured and empty checks.
fast = step('fast', 'Run ${{ matrix.check }} (bash)')
for setup, command, expected in [('dotnte', 'true', 1), ('dotnte', '', 0),
                                 ('DOTNET', 'true', 0), ('none', 'true', 0)]:
    result = subprocess.run(['bash', '-e', '-c', fast], env=dict(
        os.environ, CHECK='lint', LINT_CMD=command, TYPECHECK_CMD='', TEST_CMD='',
        SETUP_CMD='', SETUP=setup), capture_output=True, text=True)
    assert result.returncode == expected, result
print('ok fast setup validation rejects typos and preserves empty checks')

base = 'release#&+%2F1'
status = dict(context='merge-conflict', state='success',
              description=f'No merge conflict with {base}; pull_request CI can run.',
              target_url='https://github.com/o/r/pull/8')
for mode in ('unchanged', 'changed', 'second-page', 'read-error'):
    posts = []
    queries = []

    def respond(req, timeout):
        path = urlsplit(req.full_url).path
        query = parse_qs(urlsplit(req.full_url).query)
        if req.data is not None:
            posts.append(json.loads(req.data))
            result = {}
        elif path.endswith('/statuses'):
            if mode == 'read-error':
                raise OSError('unavailable')
            if mode == 'second-page' and query['page'] == ['1']:
                result = [dict(context='other')] * 100
            else:
                result = [dict(status, state='failure')] if mode == 'changed' else [status]
        elif path.endswith('/pulls'):
            queries.append(query)
            result = [dict(number=8)]
        elif path.endswith('/pulls/8'):
            result = dict(state='open', base=dict(ref=base), head=dict(sha=sha), mergeable=True)
        else:
            raise AssertionError(path)
        return io.BytesIO(json.dumps(result).encode())

    env = dict(BASES=base, GITHUB_REPOSITORY='o/r', GITHUB_API_URL='https://api.github.com',
               GITHUB_SERVER_URL='https://github.com', GH_TOKEN='fixture', GITHUB_EVENT_NAME='schedule')
    with patch.dict(os.environ, env), patch('urllib.request.urlopen', respond):
        try:
            exec(compile(source, 'merge-conflict', 'exec'), {})
        except SystemExit as error:
            assert mode == 'read-error' and error.code == 1
        else:
            assert mode != 'read-error'
    assert queries[0] == dict(state=['open'], base=[base], per_page=['100'], page=['1'])
    assert posts == ([status] if mode == 'changed' else []), (mode, posts)
    print('ok merge-conflict', mode)

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    binary = work / 'bin'
    binary.mkdir()
    gh = binary / 'gh'
    gh.write_text('''#!/usr/bin/env bash
set -eu
while [ "$1" != --jq ]; do shift; done
shift
printf '%s' "$PR_FIXTURE" | jq -r "$1"
''')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH'],
               GITHUB_REPOSITORY='o/r', GITHUB_EVENT_NAME='workflow_dispatch',
               PR_NUMBER='', EXPECTED_SHA='', SKIP_AUTHORS='[]')
    target = step('ocr', 'Resolve review target (head SHA, base ref, fork, draft, state)')
    for selector in ('feature', 'https://github.com/o/r/pull/8', '08'):
        output = work / 'output'
        output.write_text('')
        fixture = dict(headRefOid=sha, baseRefName='main', isCrossRepository=False,
                       isDraft=False, state='OPEN', author=dict(login='person'), number=8)
        subprocess.run(['bash', '-c', target], env=dict(env, DISPATCH_PR=selector,
                       GITHUB_OUTPUT=str(output), PR_FIXTURE=json.dumps(fixture)), check=True)
        assert 'number=8\n' in output.read_text()
    print('ok OCR resolved number for branch, URL and leading-zero input')

    # A fake installer asserts that PR-controlled configuration is out of scope.
    npm = binary / 'npm'
    npm.write_text('''#!/usr/bin/env bash
set -eu
case "$PWD" in "$RUNNER_TEMP"/ocr-install.*) ;; *) exit 7 ;; esac
[ ! -e bunfig.toml ]
[ "$*" = "install -g --ignore-scripts @alibaba-group/open-code-review@1.12.0" ]
mkdir -p "$npm_config_prefix/bin"
printf '#!/bin/sh\nexit 0\n' > "$npm_config_prefix/bin/ocr"
chmod +x "$npm_config_prefix/bin/ocr"
''')
    npm.chmod(0o755)
    checkout = work / 'checkout'
    checkout.mkdir()
    (checkout / 'bunfig.toml').write_text('[install]\nregistry="https://untrusted.invalid"\n')
    install = step('ocr', 'Install pinned ocr CLI')
    subprocess.run(['bash', '-c', install], cwd=checkout,
                   env=dict(env, RUNNER_TEMP=str(work), GITHUB_PATH=str(work / 'path'), OCR_VERSION='1.12.0'), check=True)
    print('ok OCR installer executes outside PR checkout')
PY

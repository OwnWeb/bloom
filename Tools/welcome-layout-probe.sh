#!/bin/zsh
# Runs the welcome transition regression in an invisible, isolated bundle after swift build.
set -euo pipefail
cd "$(dirname "$0")/.."

source Tools/probe-app.sh
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/bloom-welcome-probe.XXXXXX")"
probe_app="$probe_root/Bloom Welcome Probe.app"
bloom_prepare_probe_app "$probe_app" "be.spatie.bloom.welcome-probe" "Bloom Welcome Probe"

# Refuse a release or stale binary, which would ignore the flag and start the application.
python3 - "$probe_app/Contents/MacOS/Bloom" "$probe_root" <<'PY'
import json
import pathlib
import subprocess
import sys

binary, root = sys.argv[1:]
if b'--welcome-layout-probe' not in pathlib.Path(binary).read_bytes():
    raise SystemExit('Build the debug app with swift build before running this probe.')
for scenario in ('all-clear', 'no-agent', 'signed-out-github'):
    subprocess.run(
        ['open', '-g', '-n', '-W', '-a', str(pathlib.Path(binary).parents[2]),
         '--stdout', f'{root}/{scenario}.json', '--stderr', f'{root}/{scenario}.log',
         '--args', '--welcome-layout-probe', '--setup-rehearsal', scenario],
        timeout=45, check=True,
    )
    report = pathlib.Path(root, f'{scenario}.json').read_text()
    print(f'{scenario}: {report}')
    if not json.loads(report)['passed']:
        raise SystemExit(f'{scenario} failed; evidence: {root}')
print(f'Probe evidence: {root}')
PY

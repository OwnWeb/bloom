#!/bin/zsh
# Runs the diff comment regression in an invisible, isolated bundle after swift build.
# Pass --review-compare-eager to also measure the previous 5,000-line renderer.
# Pass --review-navigation-only to check file jumps without sending any input events.
# Pass --changes-review-only to check history and staging in invisible windows, without input events.
# Pass --review-fold-only to check that ticking a file folds it and that the row controls line up.
# Pass --tab-store-only to check what a workspace's tabs are written as and what comes back.
# Pass --terminal-scroller-only to check both terminals' scroll bars follow the system's setting.
# It crashes rather than fails on the code these regressions were written for.
# Set BLOOM_PROBE_VERBOSE=1 to print the probe's own log on a passing run as well as a failing
# one, which is how a check that only goes wrong on someone else's machine is read.
set -euo pipefail
cd "$(dirname "$0")/.."

source Tools/probe-app.sh
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/bloom-review-probe.XXXXXX")"
probe_app="$probe_root/Bloom Review Probe.app"
bloom_prepare_probe_app "$probe_app" "be.spatie.bloom.review-probe" "Bloom Review Probe"

# Refuse a release or stale binary, which would ignore the flag and start the application.
python3 - "$probe_app/Contents/MacOS/Bloom" "$probe_root" "$@" <<'PY'
import json
import os
import shutil
import pathlib
import subprocess
import sys

binary, root, *arguments = sys.argv[1:]
if b'--review-run-probe' not in pathlib.Path(binary).read_bytes():
    raise SystemExit('Build the debug app with swift build before running this probe.')
# A real, disposable worktree for full-screen review snapshots and navigation checks.
fixture = pathlib.Path(root, 'fixture')
fixture.mkdir()
for name, body in {
    'Config/features.json': '{"free_shipping": false}\n',
    'Docs/legacy-shipping.md': 'Shipping costs 4.95 for every order.\n',
    'README.md': '# Checkout\n\nShipping costs 4.95 for every order.\n',
    'Sources/Checkout.swift': 'struct Checkout {\n    var shipping: Decimal { 4.95 }\n}\n',
}.items():
    target = fixture / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body)
def git(*args):
    subprocess.run(['git', '-C', str(fixture), *args], check=True, capture_output=True)
git('init', '-b', 'main')
git('add', '.')
git('-c', 'commit.gpgsign=false', '-c', 'user.name=Review Probe',
    '-c', 'user.email=probe@example.test', 'commit', '-m', 'Fixture')
(fixture / 'Config/features.json').write_text('{"free_shipping": true, "threshold": 50}\n')
(fixture / 'Docs/legacy-shipping.md').unlink()
(fixture / 'Docs/review-checklist.md').write_text('# Review checklist\n\n- Check empty carts.\n- Check quantities.\n')
(fixture / 'README.md').write_text(
    '# Checkout\n\nOrders of 50 or more qualify for free shipping.\n'
    'Smaller orders cost 4.95 to ship.\nEmpty carts have no shipping charge.\n'
    '\n## Review\n\nRead the changes and add comments beside the relevant lines.\n'
)
(fixture / 'Sources/Checkout.swift').write_text(
    '    struct Checkout {\n    var freeShippingThreshold: Decimal = 50\n'
    '    var shippingFee: Decimal = 4.95\n\n'
    '    var qualifiesForFreeShipping: Bool {\n        subtotal >= freeShippingThreshold\n    }\n'
    '}\n'
)
(fixture / 'Sources/LongReview.swift').write_text(
    ''.join(f'let reviewLine{line} = {line}\n' for line in range(1800 if '--review-scroll-profile' in arguments else 120))
)
navigation = pathlib.Path(root, 'navigation')
navigation.mkdir()
subprocess.run(['git', '-C', str(navigation), 'init', '-b', 'main'], check=True, capture_output=True)
subprocess.run(['git', '-C', str(navigation), '-c', 'commit.gpgsign=false',
                '-c', 'user.name=Review Probe', '-c', 'user.email=probe@example.test',
                'commit', '--allow-empty', '-m', 'Fixture'], check=True, capture_output=True)
for index in range(8):
    (navigation / f'File{index:02}.swift').write_text(''.join(
        f'let file{index}Line{line} = "' + ('wrapped text ' * (index + 4)) + '"\n'
        for line in range(30 + index * 7)
    ))
# **Not `check=True`, and the reason is a probe that answers too quickly.** `open -W` waits for
# the application by asking the kernel to watch a process that has to still be there when it
# asks, and a probe with no window to draw can be finished before that: on the CI runner
# a short probe came back "Unable to block on applications (initial call to kevent()
# failed: No such process)" and exit 1, having written a perfectly good result a moment earlier.
# What the exit status of `open` cannot tell apart, the result file can, so the result is what
# is believed: written means it ran, absent means it died. See the crash branch below, which is
# the case this must not swallow.
try:
    open_arguments = ['open']
    open_arguments.append('-g')
    open_arguments.extend([
        '-n', '-W', '-a', str(pathlib.Path(binary).parents[2]),
        '--stdout', f'{root}/result.json', '--stderr', f'{root}/probe.log',
        '--args', '--review-run-probe', root, *arguments,
    ])
    subprocess.run(
        open_arguments,
        timeout=120,
    )
except subprocess.TimeoutExpired:
    print(pathlib.Path(root, 'probe.log').read_text(), file=sys.stderr)
    raise
result_path = pathlib.Path(root, 'result.json')
report = result_path.read_text() if result_path.exists() else ''
print(report)
if os.environ.get('BLOOM_PROBE_VERBOSE'):
    print(pathlib.Path(root, 'probe.log').read_text(), file=sys.stderr)
# A probe that died wrote nothing, and `open -W` reports its own exit status rather than the
# app's, so a crash arrives here as an empty file. It used to come out as a JSON traceback, which
# reads as the harness being broken rather than the thing under test.
try:
    passed = json.loads(report)['passed']
except json.JSONDecodeError:
    print(pathlib.Path(root, 'probe.log').read_text(), file=sys.stderr)
    raise SystemExit(f'Probe wrote no result: it crashed or was killed. Evidence: {root}')
if not passed:
    if os.environ.get('RUNNER_TEMP'):
        evidence = pathlib.Path(os.environ['RUNNER_TEMP'], 'bloom-review-probe')
        evidence.mkdir(exist_ok=True)
        for item in pathlib.Path(root).iterdir():
            if item.suffix in {'.png', '.json', '.log'}:
                shutil.copy2(item, evidence / item.name)
    print(pathlib.Path(root, 'probe.log').read_text(), file=sys.stderr)
    raise SystemExit(f'Probe failed; evidence: {root}')
print(f'Probe evidence: {root}')
PY

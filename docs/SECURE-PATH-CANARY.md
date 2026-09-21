# Secure-path compatibility canary

The secure-path canary is an explicitly non-production extension of `Tools/machine-test.py`. It is
a compatibility, isolation and lifecycle check. Its durations are diagnostic data, never pass or
fail thresholds.

The canary uses `Tests/fixtures/SecurePathCanary`, the machine test's deterministic runbloom.app
substitute and a `bloomtest-` Sprite. It does not deploy or release anything. The ordinary machine
test cleanup deletes the machine, while `Tools/sweep-test-machines.sh` remains the recovery path if
the local process is killed before its `finally` block runs.

It refuses to start unless all three gates are present:

```bash
export BLOOM_SECURE_PATH_CANARY=1
export BLOOM_CANARY_ENVIRONMENT=test
export BLOOM_CANARY_ALLOWED_ORGANISATIONS="$BLOOM_TEST_SPRITES_ORG"
python3 Tools/machine-test.py \
  --package bloom-runner-linux-x86_64-VERSION.tar.gz \
  --secure-path-canary \
  --canary-report .canary/secure-path.json
```

Only a local fake machine API is accepted. `development`, `test` and `staging` are the only allowed
environment names. Do not point this harness at production, provide production credentials, or use
`--keep` with the canary.

The JSON report contains step names, pass or fail status, informational durations, non-sensitive
machine, workspace, turn and service identifiers, and cleanup status. It deliberately excludes
credentials, grants, workspace bearers, handoff ids, prompts and provider response bodies.

The model phase drives the installed agent through the dynamically selected loopback gateway. It
checks a streamed first event and completion, renewal, exact binding, single-use stream ids,
signed cancellation, turn revocation, and the separation between the server grant and the random
64-character local bearer. A terminal and its tmux server are checked separately and must receive
neither form of model authority.

Tests, builds, linters, scripts, the canary and CI were deliberately not run while this harness was
assembled. Execute the documented command only as a separate final-consolidation validation step.

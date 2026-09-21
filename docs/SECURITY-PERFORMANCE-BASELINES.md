# Security, performance and compatibility baselines

This is the comparison contract for the Runner isolation, GitHub broker, model gateway and
secret-scoping changes. Measurements are evidence, not test assertions. Correctness tests must not
fail because a shared machine took longer than another one.

## Existing coverage

The baseline work builds on these existing hooks:

| Area | Existing evidence |
| --- | --- |
| Real machine lifecycle | `Tools/machine-test.py` creates a throwaway development Sprite, boots a packaged Runner against a fake runbloom.app, checks setup, summaries and events, and deletes the machine. `--sleep`, `--restart`, `--terminal`, `--outage`, `--update` and `--live` exercise specific paths. |
| Runner package boot | `Tools/runner-smoke.py` boots the packaged server against a fake control plane in Linux CI. |
| Update recovery | `Tools/runner-start-probe.sh` checks health failure rollback, secret URL masking and sandbox provisioning without root or network access. |
| Setup and persistence | `MachineSetupTests` check clone, prepare, setup, resume, later-start resume-only behaviour, setup interruption, service start after setup, log masking and the `gh` wrapper. |
| Services | `ServiceSupervisorTests` check readiness, dependency ordering, restart backoff, environment refresh and process-group cleanup. |
| Credentials | `WorkspaceHTTPServerTests`, `LocalCredentialAuthorityTests` and `RunbloomClientTests` check caller binding, read versus write authority, local-secret refusal and token redaction. |
| Streams | `WorkspaceHTTPServerTests.eventStream` checks event delivery and the sleep boundary. `Tools/machine-test.py --live` checks a real provider turn. |
| Usage | Runner usage reports already carry cumulative CPU seconds, memory GB-seconds and boot identity. `Tools/machine-test.py --outage` samples Runner RSS while reports queue. |

`Tools/performance-baseline.py` adds local process references without contacting a provider or a
credential authority. `Tools/machine-test.py --metrics FILE` records the remote lifecycle timings
that only a real machine can supply. The metrics file contains no token, environment value, machine
URL or credential response.

## Local benchmark

Run from the repository root while the machine is otherwise quiet:

```sh
python3 Tools/performance-baseline.py \
  --runs 15 \
  --warmups 3 \
  --stream-seconds 10 \
  --output /tmp/bloom-baseline.json
```

The definitions are:

- `shell_noop`: process spawn through successful exit of `/bin/zsh -dfc :`.
- `git_version` and `gh_version`: executable startup through successful version output, with no
  network request.
- `git_status`: process spawn through a tracked-file-only status of this checkout.
- `git_credential_fill`: `git credential fill` through a temporary local helper in an isolated
  home and Git configuration. The input host is `benchmark.invalid`. No system helper, Keychain,
  token or network request is used.
- `terminal_startup.cold`: start an isolated tmux server and session until its shell writes a
  marker.
- `terminal_startup.warm`: start another session on that isolated server until its shell writes a
  marker.
- `synthetic_long_stream`: a separate process encodes and decodes 50 JSON model-delta-shaped events
  per second, with 4 KiB payloads, for ten seconds. RSS is sampled every 100 ms and child CPU time
  comes from `wait4`. This is an OS and runtime reference, not a measurement of Bloom's event path.

Each startup result reports minimum, median, nearest-rank p95 and maximum. Compare medians and p95,
not individual samples. Keep the JSON from both revisions and do not compare results from different
machine classes, OS versions, power modes or major tool versions.

The checked-in sample at `docs/baselines/2026-09-21-main-macos.json` was measured from product commit
`0b9cb9529469100dee83822e84741d297ef787c2` on an Apple M4 Pro with 14 logical CPUs and 48 GiB RAM,
macOS 27.0, Python 3.14.3, Git 2.54.0, gh 2.88.1 and tmux 3.6a. The dirty flag is true because the
benchmark and its machine-test instrumentation were uncommitted; no product source was changed.

| Measurement | Median | p95 |
| --- | ---: | ---: |
| Shell no-op | 5.686 ms | 6.135 ms |
| Git version | 12.522 ms | 13.499 ms |
| Git status | 16.994 ms | 18.558 ms |
| Isolated credential fill | 25.897 ms | 28.176 ms |
| gh version | 29.330 ms | 30.665 ms |
| Terminal cold | 19.954 ms | 21.457 ms |
| Terminal warm | 13.144 ms | 14.399 ms |

The synthetic stream processed 1.953 MiB in 10.122 seconds, used 0.131 child CPU seconds and peaked
at 23,871,488 bytes RSS. These numbers do not establish remote turn or Runner performance.

## Remote benchmark

A remote run creates billable development infrastructure and must be started explicitly. It uses a
fake runbloom.app and a public fixture repository by default. `--live` additionally requires the
documented local provider credential. Never put a credential or token on the command line.

Against a packaged candidate:

```sh
BLOOM_TEST_SPRITES_ORG=<development-org> \
python3 Tools/machine-test.py \
  --package bloom-runner-linux-x86_64-<version>.tar.gz \
  --restart \
  --terminal \
  --sleep 25 \
  --metrics /tmp/bloom-machine-candidate.json
```

Against an already published Runner release:

```sh
BLOOM_TEST_SPRITES_ORG=<development-org> \
python3 Tools/machine-test.py \
  --from-release runner-v<version> \
  --restart \
  --terminal \
  --sleep 25 \
  --metrics /tmp/bloom-machine-release.json
```

Add `--live` only for turn measurements. It records request-to-accept, request-to-provider-start
and request-to-first-assistant-text. The latter is the first assistant text event currently exposed
by the machine test, not necessarily the provider's first token. The model gateway should add a
first-provider-event timestamp so token latency can be separated from transcript publication.

The remote metrics definitions are:

- `runner_service_start_to_health`: before service creation through the first successful public
  health response.
- `cold_service_start_to_setup_finished`: the same start through setup reaching succeeded, failed
  or skipped.
- `remote_terminal_request_to_accept`: before `run_script` RPC through its accepted response.
- `remote_terminal_request_to_shell`: before `run_script` RPC through the tmux pane being present.
- `service_restart_to_health`: before asking Sprite to restart the service through public health.
- `cold_wake_first_health`: before the first health request after the idle wait through its response.
  `provider_paused` says whether the provider was observed paused first.
- `remote_turn_request_to_accept`: before send RPC through its accepted response.
- `remote_turn_request_to_provider_start`: before send RPC through the fake runbloom.app receiving
  the turn-start registration.
- `remote_turn_request_to_first_assistant_text`: before send RPC through the first matching assistant
  text event.

Run each baseline and candidate three times. Keep failed and partial metric files. A failed run is
compatibility evidence and must not be discarded as an outlier. For successful runs, compare the
median of the three values. Record the Runner revision, provider region and machine size beside the
files. Run baseline and candidate close together to reduce provider-load drift.

No remote numbers were collected for current main in this change. Doing so would create cloud
state, and live turn latency additionally requires a provider credential. The next authorised
development-machine run should capture current main or its latest Runner tag before the secure path
is enabled.

## Focused compatibility checks

The deterministic checks are:

```sh
zsh Tools/runner-start-probe.sh
swift test --filter MachineSetupTests
swift test --filter ServiceSupervisorTests
swift test --filter WorkspaceHTTPServerTests
```

Runner tests are also run as an unprivileged user on the Linux CI image, which is the shipping
platform. Do not replace that gate with a Mac-only result.

A There There-style canary must use a dedicated, non-production repository and disposable data. Its
committed lock files and `.bloom/settings.toml` should exercise the actual stack, not sleep commands
standing in for it:

1. `prepare` installs system packages and runtimes without personal secrets.
2. `setup` runs `composer install` and `npm ci`, creates the disposable database, migrates and seeds
   it, and builds any required assets.
3. `resume` checks the persistent database and a marker written by setup. It must not reinstall all
   dependencies.
4. Services include the HTTP app plus Horizon, Reverb and Vite, or the project's true equivalents.
   Readiness is explicit. Consumers use `depends_on` for the app, database or broker they require.
5. The preview answers through `BLOOM_APP_PORT`. A queue job completes, a broadcast reaches a test
   client and a Vite asset is served.
6. A file, database row, dependency directory and service-generated marker survive a service
   restart and a provider-confirmed cold wake.
7. After the wake, `resume` runs once before services. All services become ready without manual
   intervention, duplicate workers or stale ports.

Record clone, prepare, setup, resume, each readiness transition and first healthy preview
separately. Setup duration alone cannot show whether a dependency waited correctly.

## Proposed regression budgets

These are initial review thresholds, not correctness test timeouts. Ratify remote thresholds after
three current-main development-machine runs.

| Area | Proposed budget |
| --- | --- |
| Local process and credential startup | Median may not increase by both 20 per cent and 5 ms. P95 may not increase by both 30 per cent and 10 ms. |
| Local terminal startup | Median may not increase by both 20 per cent and 10 ms. P95 may not increase by both 30 per cent and 20 ms. |
| Remote service, terminal and warm wake | Median may not increase by both 20 per cent and 250 ms. |
| Cold wake and setup | Median may not increase by both 20 per cent and 2 seconds. Setup may instead use 15 seconds as the absolute allowance when dependency download variance dominates. |
| First provider event and first assistant text | Median may not increase by both 20 per cent and 500 ms. Report provider-event and transcript-publication time separately. |
| Long stream CPU | CPU seconds may not rise by more than 15 per cent on the same event corpus and duration. |
| Long stream memory | Peak RSS may not rise by both 20 per cent and 32 MiB. End RSS after a five-minute quiet period must return within 16 MiB of its pre-stream level. |

Any statistically repeatable regression over budget needs an explanation or a fix. A security
failure has no performance tradeoff budget.

## Secure-path canary

Run this after PR #329 and the server credential and model-gateway cutovers land:

- [ ] An unauthenticated request, incomplete machine identity, unavailable broker or missing model
  grant fails closed. No legacy credential or direct provider fallback is used.
- [ ] Setup, resume, services and unrelated terminals cannot obtain a person's write credential.
  Another person's turn cannot reuse it.
- [ ] Git and `gh` work for the authorised repository and operation during the bound turn. They fail
  for a different repository, after the turn ends and from an unregistered descendant.
- [ ] No token or secret appears in arguments, process listings, setup and service logs, captured
  RPC data, environment dumps, Git configuration, credential files or the worktree. Verification
  compares hashes or booleans, never values.
- [ ] Cancelling and ending a turn removes its full process group. No child keeps a grant socket,
  model stream or credential alive. Service children survive only when they belong to the service
  supervisor, and `stopAll` leaves no descendants.
- [ ] The baseline and candidate use the same Runner package inputs, machine size, region, fixture,
  model and prompt. Startup, first-event, streaming CPU and RSS stay within the budgets above.
- [ ] The dedicated complex canary completes Composer and npm installation, database setup,
  dependency-ordered service readiness, queue work, broadcast, Vite delivery and preview health.
- [ ] A provider-confirmed cold wake preserves the worktree, dependency caches, database and marker;
  runs resume before services; and restores every service without duplicates.
- [ ] A failed setup or service readiness check is visible, retryable and does not start dependants.
- [ ] Update rollback and service recovery remain green through `Tools/runner-start-probe.sh` and a
  real-machine `--restart --update` rehearsal.

Rerun the local JSON baseline, the focused Runner tests, the real-machine remote baseline, and the
complex canary after PR #329 merges. Rerun the live turn measurements after the model gateway and
server cutover, because current main cannot provide a comparable first-provider-event measurement.

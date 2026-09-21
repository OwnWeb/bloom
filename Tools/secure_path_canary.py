#!/usr/bin/env python3
"""Secure-path compatibility canary support for machine-test.py.

This module contains no entry point. The existing machine test owns machine creation, transport and
teardown. Keeping the canary behind that orchestration means it inherits the bloomtest machine name,
crash sweeper and unconditional machine deletion instead of growing a second cloud lifecycle.
"""

import contextlib
import json
import os
import pathlib
import re
import tarfile
import time

FIXTURE = pathlib.Path(__file__).resolve().parents[1] / "Tests/fixtures/SecurePathCanary"
ALLOWED_ENVIRONMENTS = {"development", "test", "staging"}
SENSITIVE_KEYS = re.compile(
    r"(secret|token|grant|credential|authorization|prompt|response|handoff)", re.IGNORECASE
)
SAFE_IDENTIFIER_KEYS = {
    "machine_id", "workspace_id", "turn_id", "service_id", "request_id", "revision",
}


class CanaryBoundaryError(RuntimeError):
    def __init__(self, boundary, message):
        super().__init__(message)
        self.boundary = boundary


class CanaryReport:
    """A deliberately small allowlisted report. Arbitrary exception data never enters it."""

    def __init__(self, runner_version, machine_id, workspace_id):
        self.value = {
            "schema": "bloom_secure_path_canary_v1",
            "non_production": True,
            "runner_version": runner_version,
            "machine_id": machine_id,
            "workspace_id": workspace_id,
            "steps": [],
            "cleanup": {"status": "pending"},
        }

    @contextlib.contextmanager
    def step(self, name, identifiers=None):
        began = time.perf_counter()
        entry = {"name": name, "status": "running"}
        if identifiers:
            entry["ids"] = self._identifiers(identifiers)
        self.value["steps"].append(entry)
        try:
            yield
        except CanaryBoundaryError as error:
            entry.update({
                "status": "failed",
                "boundary": error.boundary,
                "message": str(error),
                "duration_ms": round((time.perf_counter() - began) * 1000, 1),
            })
            raise
        except BaseException:
            entry.update({
                "status": "failed",
                "boundary": name,
                "message": "The step failed. Inspect the redacted Runner and fake-server logs.",
                "duration_ms": round((time.perf_counter() - began) * 1000, 1),
            })
            raise
        else:
            entry.update({
                "status": "passed",
                "duration_ms": round((time.perf_counter() - began) * 1000, 1),
            })

    def cleanup(self, status, identifiers=None):
        self.value["cleanup"] = {"status": status}
        if identifiers:
            self.value["cleanup"]["ids"] = self._identifiers(identifiers)

    def write(self, path):
        path = pathlib.Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.value, indent=2, sort_keys=True) + "\n")

    @staticmethod
    def _identifiers(values):
        result = {}
        for key, value in values.items():
            if key not in SAFE_IDENTIFIER_KEYS:
                raise ValueError(f"{key} is not an allowed canary report identifier")
            result[key] = value
        return result


def require_non_production(organisation, base_url):
    if os.environ.get("BLOOM_SECURE_PATH_CANARY") != "1":
        raise SystemExit("Refusing secure-path canary: set BLOOM_SECURE_PATH_CANARY=1 explicitly.")
    environment = os.environ.get("BLOOM_CANARY_ENVIRONMENT", "")
    if environment not in ALLOWED_ENVIRONMENTS:
        raise SystemExit(
            "Refusing secure-path canary: BLOOM_CANARY_ENVIRONMENT must be development, test or staging."
        )
    allowed = {
        value.strip() for value in os.environ.get("BLOOM_CANARY_ALLOWED_ORGANISATIONS", "").split(",")
        if value.strip()
    }
    if not allowed or organisation not in allowed:
        raise SystemExit(
            "Refusing secure-path canary: the Sprites organisation is not explicitly allowlisted in "
            "BLOOM_CANARY_ALLOWED_ORGANISATIONS."
        )
    if base_url not in {"http://127.0.0.1:9000", "http://localhost:9000"}:
        raise SystemExit("Refusing secure-path canary: its machine API must be the local deterministic substitute.")


def assert_redacted(value):
    """Statically usable guard for report payloads before they leave the harness."""
    if isinstance(value, dict):
        for key, item in value.items():
            if SENSITIVE_KEYS.search(str(key)) and key not in SAFE_IDENTIFIER_KEYS:
                raise CanaryBoundaryError("diagnostics.redaction", f"Sensitive report field refused: {key}")
            assert_redacted(item)
    elif isinstance(value, list):
        for item in value:
            assert_redacted(item)


def fixture_archive(destination):
    """Create the upload archive. Called only during an explicitly enabled canary run."""
    with tarfile.open(destination, "w:gz") as archive:
        for path in sorted(FIXTURE.rglob("*")):
            if path.is_file():
                archive.add(path, arcname=path.relative_to(FIXTURE))


class SecurePathCanary:
    """Assertions that run inside machine-test.py's already-owned machine lifecycle."""

    expected_services = {
        "app": "CANARY_APP_SECRET",
        "queue": "CANARY_QUEUE_SECRET",
        "realtime": "CANARY_REALTIME_SECRET",
        "assets": "CANARY_ASSETS_SECRET",
    }

    def __init__(self, *, machine, workspace, public_url, report, run_on, push, rpc, session,
                 requests, local, proxy_port, wait_for):
        self.machine = machine
        self.workspace = workspace
        self.public_url = public_url
        self.report = report
        self.run_on = run_on
        self.push = push
        self.rpc = rpc
        self.session = session
        self.requests = requests
        self.local = local
        self.proxy_port = proxy_port
        self.wait_for = wait_for

    def install_fixture(self, scratch):
        archive = pathlib.Path(scratch) / "secure-path-canary-fixture.tar.gz"
        fixture_archive(archive)
        self.push(self.machine, str(archive), "/home/sprite/secure-path-canary-fixture.tar.gz")
        with self.report.step("fixture.install"):
            self.run_on(self.machine, "sprite-env services stop bloom", timeout=120)
            self.run_on(
                self.machine,
                "set -eu; cd /home/sprite/workspace; "
                "find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +; "
                "tar -xzf /home/sprite/secure-path-canary-fixture.tar.gz; "
                "rm -f /home/sprite/secure-path-canary-fixture.tar.gz; "
                "git add -A; git -c user.name=Bloom -c user.email=canary@invalid commit -qm 'Install canary fixture'"
            )
            self.run_on(self.machine, "sprite-env services start bloom", timeout=120)

    def assert_provisioning(self):
        with self.report.step("provisioning.identity_and_capabilities"):
            state = self._fake_state()
            if not state.get("machine_registered"):
                raise CanaryBoundaryError("provisioning.machine_identity", "Machine identity was not registered.")
            summaries = [request for request in self.requests() if request["path"].endswith("/summary")]
            if not summaries:
                raise CanaryBoundaryError("provisioning.summary", "No protected summary arrived after registration.")
            capabilities = summaries[0].get("body", {}).get("bloom_runner_capabilities", [])
            if "machine_identity_proof_v1" not in capabilities:
                raise CanaryBoundaryError(
                    "provisioning.capability_readiness",
                    "Machine identity capability was not advertised after proof readiness.",
                )

    def assert_manifest_and_scopes(self):
        with self.report.step("services.manifest_and_scopes"):
            manifests = [request for request in self.requests() if request["path"].endswith("/service-manifest")]
            if not manifests:
                raise CanaryBoundaryError("services.manifest", "The Runner did not synchronize a service manifest.")
            services = manifests[-1]["body"].get("services", [])
            ids = [service.get("id") for service in services]
            if ids != list(self.expected_services):
                raise CanaryBoundaryError("services.manifest", f"Unexpected stable service ids: {ids!r}")

            expected = self._fake_state()["secret_digests"]
            states = self.wait_for(
                "canary services publish launch evidence",
                lambda: (lambda found: found if set(found) == set(self.expected_services) else None)(
                    self._service_states()
                ),
                180,
            )
            for service, variable in self.expected_services.items():
                state = states.get(service)
                if not state:
                    raise CanaryBoundaryError("services.lifecycle", f"Service {service} did not publish launch evidence.")
                if state.get("present_scopes") != [variable]:
                    raise CanaryBoundaryError("services.secret_scope", f"Service {service} observed another secret scope.")
                if state.get("scope_digest") != expected.get(variable):
                    raise CanaryBoundaryError("services.secret_scope", f"Service {service} received the wrong scoped value.")
                if not state.get("ordinary") or state.get("provider_names"):
                    raise CanaryBoundaryError("services.environment", f"Service {service} received a forbidden environment.")

            starts = {service: states[service]["started_at_ns"] for service in states}
            if not (starts["app"] <= starts["queue"] and starts["app"] <= starts["realtime"]
                    and starts["realtime"] <= starts["assets"]):
                raise CanaryBoundaryError("services.dependencies", "The service dependency order was not preserved.")

    def rerun_setup(self):
        with self.report.step("setup.one_use_scope"):
            before = self._fake_state().get("consumed_handoffs", 0)
            result = self.rpc(
                self._url(), self.session(), {"kind": "run_setup"}
            )
            if result.get("kind") != "accepted":
                raise CanaryBoundaryError("setup.launch", "The fixture setup was not accepted.")
            self.wait_for("fixture setup evidence", lambda: self._json_file(".bloom-canary/setup.json"), 180)
            setup = self._json_file(".bloom-canary/setup.json")
            expected = self._fake_state()["secret_digests"]
            if setup.get("present_scopes") != ["CANARY_SETUP_SECRET"]:
                raise CanaryBoundaryError("setup.secret_scope", "Setup observed a secret outside setup scope.")
            if setup.get("scope_digest") != expected.get("CANARY_SETUP_SECRET"):
                raise CanaryBoundaryError("setup.secret_scope", "Setup received the wrong scoped value.")
            if setup.get("provider_names") or not setup.get("ordinary"):
                raise CanaryBoundaryError("setup.environment", "Setup received a forbidden environment.")
            after = self._fake_state().get("consumed_handoffs", 0)
            if after != before + 1:
                raise CanaryBoundaryError("setup.handoff", "Setup did not consume exactly one handoff.")

    def assert_restart_persistence(self):
        with self.report.step("lifecycle.runner_restart"):
            original = self._service_states()
            self.run_on(self.machine, "sprite-env services restart bloom", timeout=120)
            self.wait_for(
                "Runner health after canary restart",
                lambda: self.run_on(self.machine, "curl -fsS http://127.0.0.1:8081/_bloom/health", timeout=30),
                120,
            )
            self.wait_for(
                "fixture resume evidence",
                lambda: (self._json_file(".bloom-canary/resume.json") or {}).get("persistent"),
                180,
            )
            resumed = self._json_file(".bloom-canary/resume.json")
            if resumed.get("present_scopes") or resumed.get("provider_names"):
                raise CanaryBoundaryError("lifecycle.resume_scope", "Resume observed a forbidden secret.")
            current = self.wait_for(
                "services relaunch after Runner restart",
                lambda: self._new_service_states(original), 180,
            )
            if set(current) != set(self.expected_services):
                raise CanaryBoundaryError("lifecycle.service_restart", "Not every service relaunched after restart.")
            old_pids = " ".join(str(state["pid"]) for state in original.values())
            living = self.run_on(
                self.machine,
                f"for pid in {old_pids}; do kill -0 \"$pid\" 2>/dev/null && printf '%s ' \"$pid\"; done",
            ).strip()
            if living:
                raise CanaryBoundaryError("lifecycle.process_cleanup", "A service from before restart is still alive.")

    def assert_terminal_environment(self, terminal_factory):
        with self.report.step("terminal.environment_and_git_boundary"):
            terminal = terminal_factory(self.public_url, "secure-path-canary", self.session())
            try:
                names = sorted({
                    "CANARY_SETUP_SECRET", *self.expected_services.values(),
                    "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL",
                    "XAI_API_KEY", "GROK_API_KEY", "GROK_XAI_API_BASE_URL",
                })
                expression = json.dumps(names, separators=(",", ":"))
                terminal.send(
                    "python3 -c 'import os; n=" + expression
                    + "; print(\"canary-terminal-count=\"+str(sum(bool(os.environ.get(k)) for k in n)))'\n"
                )
                count = int(terminal.until_pattern(rb"canary-terminal-count=(\d+)").group(1))
                if count != 0:
                    raise CanaryBoundaryError(
                        "terminal.environment", "The terminal or tmux server received protected credentials."
                    )
                terminal.send(
                    "test -S /var/lib/bloom/person-bound-shared/git-credentials-v2.sock "
                    "&& echo canary-git-socket=yes || echo canary-git-socket=no\n"
                )
                available = terminal.until_pattern(rb"canary-git-socket=(yes|no)").group(1)
                if available != b"yes":
                    raise CanaryBoundaryError(
                        "terminal.github_boundary", "The isolated person-bound GitHub socket is unavailable."
                    )
                terminal.send(
                    "BLOOM_PERSON_BOUND_FOUNDATION_SELF_TEST=1 gh repo view >/dev/null 2>&1; "
                    "echo canary-github-allowed=$?\n"
                )
                allowed = int(terminal.until_pattern(rb"canary-github-allowed=(\d+)").group(1))
                if allowed != 0:
                    raise CanaryBoundaryError(
                        "terminal.github_boundary", "An allowed isolated GitHub operation was refused."
                    )
                terminal.send(
                    "BLOOM_REPOSITORY=octocat/Spoon-Knife "
                    "BLOOM_PERSON_BOUND_FOUNDATION_SELF_TEST=1 gh repo view >/dev/null 2>&1; "
                    "echo canary-github-cross-workspace=$?\n"
                )
                crossed = int(
                    terminal.until_pattern(rb"canary-github-cross-workspace=(\d+)").group(1)
                )
                if crossed == 0:
                    raise CanaryBoundaryError(
                        "terminal.github_boundary", "A cross-workspace GitHub operation was accepted."
                    )
            finally:
                terminal.close()

    def assert_cold_wake(self, provider_paused):
        with self.report.step("lifecycle.cold_wake"):
            if not provider_paused:
                raise CanaryBoundaryError(
                    "lifecycle.cold_wake", "The provider never entered its non-production paused state."
                )
            resumed = self._json_file(".bloom-canary/resume.json") or {}
            if not resumed.get("persistent"):
                raise CanaryBoundaryError("lifecycle.persistence", "Fixture state did not survive the cold wake.")
            if resumed.get("present_scopes") or resumed.get("provider_names"):
                raise CanaryBoundaryError("lifecycle.resume_scope", "Cold-wake resume observed a forbidden secret.")
            states = self.wait_for(
                "canary services after cold wake",
                lambda: (lambda found: found if set(found) == set(self.expected_services) else None)(
                    self._service_states()
                ),
                180,
            )
            expected = self._fake_state()["secret_digests"]
            for service, variable in self.expected_services.items():
                state = states[service]
                if state.get("present_scopes") != [variable] \
                        or state.get("scope_digest") != expected.get(variable):
                    raise CanaryBoundaryError(
                        "lifecycle.service_scope", f"Service {service} lost isolation across cold wake."
                    )

    def assert_negative_contracts(self):
        """Ask the deterministic server for results of its closed-boundary probes."""
        with self.report.step("security.fail_closed_matrix"):
            state = self._fake_state()
            required = {
                "machine_replay", "machine_wrong_key", "machine_wrong_workspace",
                "handoff_replay", "handoff_expired", "handoff_wrong_scope", "handoff_cancelled",
                "github_cross_workspace", "github_stale_grant",
            }
            failures = sorted(name for name in required if state.get("negative_cases", {}).get(name) != "refused")
            if failures:
                raise CanaryBoundaryError("security.fail_closed", f"Negative cases did not refuse: {failures!r}")

    def assert_gateway_contracts(self):
        """Drive the merged loopback gateway through a real agent process and signed fake API."""
        with self.report.step("model.gateway"):
            ended_before = self._fake_state().get("ended_turns", 0)
            summaries = [request for request in self.requests() if request["path"].endswith("/summary")]
            if not summaries or "opaque_model_grants_v1" not in summaries[-1]["body"].get(
                "bloom_runner_capabilities", []
            ):
                raise CanaryBoundaryError(
                    "model.listener_readiness", "The live gateway capability was not advertised."
                )

            controls = {
                "agent": "claude", "model": "sonnet", "effort": "low",
                "permission_mode": "bypassPermissions", "interaction_mode": "build",
                "fast_mode": False, "output_style": "default", "codex_context_window": 0,
            }
            first = self.rpc(self.public_url, self.session(), {"kind": "new_chat", "controls": controls})["chat"]
            self.rpc(
                self.public_url, self.session(),
                {"kind": "send", "chat_id": first["id"], "text": "Complete the compatibility check."},
            )
            self.wait_for(
                "model stream completion and grant renewal",
                lambda: (lambda state: state if state.get("model_path", {}).get("completed")
                         and state.get("model_path", {}).get("renewed") else None)(self._fake_state()),
                180,
            )
            self.wait_for(
                "completed model turn revocation",
                lambda: self._fake_state().get("ended_turns", 0) >= ended_before + 1,
                120,
            )

            second = self.rpc(self.public_url, self.session(), {"kind": "new_chat", "controls": controls})["chat"]
            self.rpc(
                self.public_url, self.session(),
                {"kind": "send", "chat_id": second["id"], "text": "bloom-canary-cancel"},
            )
            self.wait_for(
                "cancellable model stream",
                lambda: self._fake_state().get("model_path", {}).get("cancellation_streaming"),
                120,
            )
            gateway = self._agent_gateway_shape()
            if gateway.get("processes", 0) < 1 or sorted(set(gateway.get("token_lengths", []))) != [64] \
                    or len(set(gateway.get("token_hashes", []))) != 1:
                raise CanaryBoundaryError(
                    "model.local_bearer", "The agent did not receive one random 64-character local bearer."
                )
            bases = gateway.get("base_urls", [])
            if len(bases) != 1 or not re.fullmatch(r"http://127\.0\.0\.1:\d+", bases[0]):
                raise CanaryBoundaryError(
                    "model.loopback_listener", "The agent did not target one dynamic loopback gateway."
                )
            if int(bases[0].rsplit(":", 1)[-1]) in {3000, 8080, 8081, 9000}:
                raise CanaryBoundaryError(
                    "model.loopback_listener", "The gateway did not use its dynamically selected listener."
                )
            state = self._fake_state()
            if set(gateway.get("token_hashes", [])) & set(state.get("model_grant_digests", [])):
                raise CanaryBoundaryError(
                    "model.authority_boundary", "An agent received server model authority instead of a local bearer."
                )
            self.rpc(self.public_url, self.session(), {"kind": "stop", "chat_id": second["id"]})
            self.wait_for(
                "signed upstream cancellation and turn end",
                lambda: (lambda current: current if current.get("model_path", {}).get("cancelled_server_side")
                         and current.get("ended_turns", 0) >= ended_before + 2 else None)(self._fake_state()),
                120,
            )

            state = self._fake_state()
            model = state.get("model_path", {})
            required = {
                "opaque_only", "local_gateway", "exact_binding", "first_event", "completed",
                "renewed", "renewal_reuses_exact_bytes", "stream_ids_single_use",
                "signed_calls", "cancelled_server_side", "turn_revoked", "terminal_refused",
                "negative_matrix",
            }
            missing = sorted(name for name in required if model.get(name) is not True)
            if missing:
                raise CanaryBoundaryError(
                    "model.gateway_contract", f"Gateway evidence is incomplete: {missing!r}"
                )
            model_requests = [
                request for request in self.requests()
                if "/model-gateway/" in request["path"] or request["path"].endswith("/model-grant-renewals")
            ]
            forbidden = {"grant", "model_request", "prompt", "response"}
            if any(forbidden & set(request.get("body") or {}) for request in model_requests):
                raise CanaryBoundaryError(
                    "diagnostics.redaction", "Recorded gateway evidence contains protected payload fields."
                )

    def _fake_state(self):
        status, body = self.local(self.proxy_port, "GET", "/test/canary-state")
        if status != 200:
            raise CanaryBoundaryError("fake_server.contract", "The canary state endpoint is unavailable.")
        return json.loads(body)

    def _service_states(self):
        output = self.run_on(
            self.machine,
            "python3 - <<'PY'\n"
            "import glob,json\n"
            "print(json.dumps({p.rsplit('/',1)[-1][:-5]:json.load(open(p)) for p in glob.glob('/home/sprite/workspace/.bloom-canary/services/*.json')}))\n"
            "PY",
        )
        return json.loads(output)

    def _new_service_states(self, previous):
        current = self._service_states()
        if set(current) != set(self.expected_services):
            return None
        if any(current[name]["pid"] == previous.get(name, {}).get("pid") for name in current):
            return None
        return current

    def _json_file(self, relative):
        output = self.run_on(
            self.machine,
            f"test -f /home/sprite/workspace/{relative} && cat /home/sprite/workspace/{relative} || true",
        ).strip()
        return json.loads(output) if output else None

    def _agent_gateway_shape(self):
        output = self.run_on(
            self.machine,
            "sudo -n python3 - <<'PY'\n"
            "import glob,hashlib,json,os,pwd\n"
            "uid=pwd.getpwnam('bloom-agent').pw_uid\n"
            "rows=[]\n"
            "for path in glob.glob('/proc/[0-9]*/cmdline'):\n"
            " try:\n"
            "  if os.stat(path.rsplit('/',1)[0]).st_uid != uid: continue\n"
            "  command=open(path,'rb').read().replace(b'\\0',b' ')\n"
            "  if b'claude' not in command or b'stream-json' not in command: continue\n"
            "  raw=open(path.rsplit('/',1)[0]+'/environ','rb').read().split(b'\\0')\n"
            "  env=dict(item.split(b'=',1) for item in raw if b'=' in item)\n"
            "  token=env.get(b'ANTHROPIC_API_KEY',b'').decode()\n"
            "  base=env.get(b'ANTHROPIC_BASE_URL',b'').decode()\n"
            "  rows.append({'length':len(token),'hash':hashlib.sha256(token.encode()).hexdigest(),'base':base})\n"
            " except (OSError,ValueError): pass\n"
            "print(json.dumps({'processes':len(rows),'token_lengths':sorted(r['length'] for r in rows),"
            "'token_hashes':sorted(r['hash'] for r in rows),'base_urls':sorted(set(r['base'] for r in rows))}))\n"
            "PY",
        )
        return json.loads(output)

    def _url(self):
        return self.public_url

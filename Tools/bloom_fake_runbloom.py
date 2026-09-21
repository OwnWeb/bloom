#!/usr/bin/env python3
"""A fake runbloom.app for bloom-runner's smoke and machine tests, and the token signing they share.

Standard library and `openssl` only. Imported by Tools/runner-smoke.py, and run on its own on a test
machine by Tools/machine-test.py:

    python3 bloom_fake_runbloom.py --port 9000 --workspace <id> --secret-stdin --jwks-file jwks.json

It answers the machine API the way runbloom.app does (summary, usage, environment, turns, scoped
secrets, person-bound GitHub grants and opaque model grants), records redacted request evidence,
and serves the key set it is given. It never holds a JWT private key: tokens are signed where the
test runs.

Opaque model authority is generated in memory and is exchanged only through signed machine calls.
`GET /test/requests` returns redacted contract evidence, never grants, session tokens, model
requests or provider response bodies. On a machine the fake listens on every interface because
`sprite proxy` arrives on the machine's internal interface rather than loopback. That authenticated
provider tunnel is the only way in, while the machine's public URL routes to port 8080 alone.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import pathlib
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def canonical_request(method, target, machine, workspace, issued_at, request_id, body):
    digest = hashlib.sha256(body).hexdigest()
    value = {
        "version": "1", "operation": "request", "method": method.upper(), "target": target,
        "machine_id": machine, "workspace_id": workspace, "issued_at": issued_at,
        "request_id": request_id, "content_sha256": digest,
    }
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def canonical_registration(machine, workspace, issued_at, request_id, public_key):
    value = {
        "version": "1", "operation": "register", "method": "POST",
        "target": f"/api/machine/workspaces/{workspace}/machine-identity",
        "machine_id": machine, "workspace_id": workspace, "issued_at": issued_at,
        "request_id": request_id, "public_key": public_key, "previous_key_id": None,
    }
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def verifies(public_key, message, signature):
    """Verify Ed25519 through OpenSSL, which this fixture already requires for JWT signing."""
    try:
        raw = b64url_decode(public_key)
        signed = b64url_decode(signature)
        if len(raw) != 32 or len(signed) != 64:
            return False
        # RFC 8410 SubjectPublicKeyInfo prefix for a raw Ed25519 public key.
        der = bytes.fromhex("302a300506032b6570032100") + raw
        with tempfile.TemporaryDirectory(prefix="bloom-canary-proof-") as directory:
            root = pathlib.Path(directory)
            (root / "public.der").write_bytes(der)
            (root / "message").write_bytes(message)
            (root / "signature").write_bytes(signed)
            result = subprocess.run([
                os.environ.get("OPENSSL", "openssl"), "pkeyutl", "-verify", "-pubin",
                "-inkey", str(root / "public.der"), "-keyform", "DER", "-rawin",
                "-in", str(root / "message"), "-sigfile", str(root / "signature"),
            ], capture_output=True)
            return result.returncode == 0
    except (OSError, ValueError):
        return False


class Issuer:
    """An Ed25519 key in its own directory, its JWKS, and tokens signed the way runbloom.app signs."""

    def __init__(self, directory, issuer, workspace):
        directory = pathlib.Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        self.issuer = issuer
        self.workspace = workspace
        self.directory = directory
        self.key = directory / "issuer.pem"
        openssl = os.environ.get("OPENSSL", "openssl")
        self.openssl = openssl
        subprocess.run([openssl, "genpkey", "-algorithm", "ed25519", "-out", str(self.key)], check=True, capture_output=True)
        self.key.chmod(0o600)
        der = subprocess.run([openssl, "pkey", "-in", str(self.key), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
        self.x = b64url(der[-32:])
        thumbprint = json.dumps({"crv": "Ed25519", "kty": "OKP", "x": self.x}, separators=(",", ":"), sort_keys=True)
        self.kid = b64url(hashlib.sha256(thumbprint.encode()).digest())

    @property
    def jwks(self):
        return json.dumps({"keys": [{"kty": "OKP", "crv": "Ed25519", "x": self.x, "kid": self.kid, "alg": "EdDSA", "use": "sig"}]}).encode()

    def token(self, use, subject, abilities, extra=None):
        now = int(time.time())
        claims = {"iss": self.issuer, "aud": f"bloom-workspace:{self.workspace}", "sub": subject, "token_use": use,
                  "abilities": abilities, "iat": now, "exp": now + (300 if use == "session" else 60),
                  "jti": b64url(os.urandom(12))}
        claims.update(extra or {})
        header = b64url(json.dumps({"alg": "EdDSA", "typ": "JWT", "kid": self.kid}).encode())
        payload = b64url(json.dumps(claims).encode())
        signing_input = self.directory / "signing-input"
        signing_input.write_bytes(f"{header}.{payload}".encode())
        signature = subprocess.run([self.openssl, "pkeyutl", "-sign", "-inkey", str(self.key), "-rawin", "-in", str(signing_input)],
                                   check=True, capture_output=True).stdout
        return f"{header}.{payload}.{b64url(signature)}"


class FakeRunbloom(http.server.ThreadingHTTPServer):
    def __init__(self, secret, jwks, workspace="01jtestworkspace00000000000",
                 machine="01jtestmachine0000000000000", registration_token="test-registration",
                 public_url="", host="127.0.0.1", port=0):
        super().__init__((host, port), Handler)
        self.secret = secret
        self.jwks = jwks
        self.workspace = workspace
        self.machine = machine
        self.registration_token = registration_token
        self.public_url = public_url
        self.machine_public_key = None
        self.machine_key_id = None
        self.proof_requests = set()
        self.service_manifest = []
        self.handoffs = {}
        self.handoff_sequence = 0
        self.consumed_handoffs = 0
        self.scoped_secrets = {
            "setup": {"CANARY_SETUP_SECRET": "setup-" + os.urandom(24).hex()},
            "app": {"CANARY_APP_SECRET": "app-" + os.urandom(24).hex()},
            "queue": {"CANARY_QUEUE_SECRET": "queue-" + os.urandom(24).hex()},
            "realtime": {"CANARY_REALTIME_SECRET": "realtime-" + os.urandom(24).hex()},
            "assets": {"CANARY_ASSETS_SECRET": "assets-" + os.urandom(24).hex()},
        }
        self.negative_cases = {}
        self.model_path = {}
        self.turn_records = {}
        self.model_grants = {}
        self.model_renewals = {}
        self.model_streams = {}
        self.model_stream_ids = set()
        self.ended_turns = set()
        self.requests = []
        self.grant = None
        self.refusal = None
        self.refuse_reports = False
        self.refused_reports = 0
        self.turns = 0
        self.github_grants = 0
        self.github_grant_states = {}
        self.person_bound_capable = False
        self.lock = threading.Lock()

    @staticmethod
    def model_binding(agent):
        return {
            "claude": ("anthropic", "anthropic_messages_stream"),
            "codex": ("openai", "openai_responses_stream"),
            "grok": ("xai", "xai_responses_stream"),
        }.get(agent)

    def model_grant(self, turn, agent, model, revision=1):
        binding = self.model_binding(agent)
        if not binding or not model:
            return None
        provider, operation = binding
        token = secrets.token_hex(32)
        expires = time.time() + 92
        grant = {
            "version": "opaque_model_grant_v1", "token": token,
            "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expires)),
            "revision": revision, "provider": provider, "model": model,
            "operation": operation,
        }
        self.model_grants[token] = {
            "turn": turn, "agent": agent, "provider": provider, "model": model,
            "operation": operation, "revision": revision, "state": "issued", "expires": expires,
        }
        return grant

    def accepts_model_stream(self, payload, record=None, used_ids=None):
        if not isinstance(payload, dict):
            return False
        record = record or self.model_grants.get(payload.get("grant"))
        used_ids = self.model_stream_ids if used_ids is None else used_ids
        try:
            request_id = payload.get("request_id")
            valid_request_id = str(uuid.UUID(request_id)) == request_id
        except (AttributeError, TypeError, ValueError):
            valid_request_id = False
        return bool(
            record and record["state"] == "issued" and record["expires"] > time.time()
            and payload.get("version") == "opaque_model_grant_v1"
            and payload.get("provider") == record["provider"]
            and payload.get("model") == record["model"]
            and payload.get("operation") == record["operation"]
            and valid_request_id and request_id not in used_ids
            and isinstance(payload.get("model_request"), dict)
        )

    def github_grant(self):
        with self.lock:
            self.github_grants += 1
            number = self.github_grants
            token = hashlib.sha256(f"fake-person-bound-grant-{number}".encode()).hexdigest()
            self.github_grant_states[token] = "issued"
        expires = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 300))
        return {"token": token, "expires_at": expires, "revision": number}

    def recorded(self, suffix):
        with self.lock:
            return [body for method, path, body in self.requests if path.endswith(suffix)]

    def canary_state(self):
        digests = {
            name: hashlib.sha256(value.encode()).hexdigest()
            for scope in self.scoped_secrets.values() for name, value in scope.items()
        }
        return {
            "machine_registered": self.machine_public_key is not None,
            "service_manifest": self.service_manifest,
            "secret_digests": digests,
            "consumed_handoffs": self.consumed_handoffs,
            "negative_cases": self.negative_cases,
            "model_path": self.model_path,
            "model_grant_digests": [
                hashlib.sha256(token.encode()).hexdigest() for token in self.model_grants
            ],
            "ended_turns": len(self.ended_turns),
            "public_url": self.public_url,
        }


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def answer(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def stream_answer(self, first, rest, request_id, cancellation=False):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(first)
            self.wfile.flush()
            self.server.model_path["first_event"] = True
            if cancellation:
                deadline = time.time() + 120
                while time.time() < deadline:
                    state = self.server.model_streams.get(request_id, {}).get("state")
                    if state == "cancelled":
                        return
                    time.sleep(0.05)
                return
            # Long enough for a 92 second grant to cross the gateway's 90 second renewal lead.
            time.sleep(3)
            self.wfile.write(rest)
            self.wfile.flush()
            self.server.model_streams[request_id]["state"] = "completed"
            self.server.model_path["completed"] = True
        except (BrokenPipeError, ConnectionResetError):
            return

    def refusal(self, status, code, message):
        return self.answer(status, json.dumps({"code": code, "message": message}).encode())

    def proof_is_valid(self, method, body):
        server = self.server
        if not server.machine_public_key or not server.machine_key_id:
            return False, "unregistered"
        try:
            version = self.headers.get("X-Bloom-Proof-Version")
            key_id = self.headers.get("X-Bloom-Proof-Key-Id")
            issued_at = int(self.headers.get("X-Bloom-Proof-Timestamp") or 0)
            request_id = self.headers.get("X-Bloom-Proof-Request-Id") or ""
            signature = self.headers.get("X-Bloom-Proof-Signature") or ""
        except ValueError:
            return False, "malformed"
        if version != "1" or key_id != server.machine_key_id:
            return False, "wrong_key"
        if abs(int(time.time()) - issued_at) > 90:
            return False, "expired"
        if request_id in server.proof_requests:
            server.negative_cases["machine_replay"] = "refused"
            return False, "replay"
        target = self.path
        canonical = canonical_request(
            method, target, server.machine, server.workspace, issued_at, request_id, body
        )
        if not verifies(server.machine_public_key, canonical, signature):
            return False, "signature"
        with server.lock:
            if request_id in server.proof_requests:
                server.negative_cases["machine_replay"] = "refused"
                return False, "replay"
            server.proof_requests.add(request_id)
        # The valid signature must stop verifying when either binding is changed.
        wrong_machine = canonical_request(
            method, target, "01jwrongmachine000000000000", server.workspace,
            issued_at, request_id, body
        )
        wrong_workspace = canonical_request(
            method, target, server.machine, "01jwrongworkspace0000000000",
            issued_at, request_id, body
        )
        if not verifies(server.machine_public_key, wrong_machine, signature):
            server.negative_cases["machine_wrong_key"] = "refused"
        if not verifies(server.machine_public_key, wrong_workspace, signature):
            server.negative_cases["machine_wrong_workspace"] = "refused"
        server.negative_cases["machine_replay"] = "refused"
        return True, None

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        server = self.server
        if self.path == "/.well-known/jwks.json":
            return self.answer(200, server.jwks)
        if self.path.startswith("/test/"):
            return self.test_api(method, body)
        if self.headers.get("Authorization") != f"Bearer {server.secret}":
            return self.answer(401, b'{"code":"invalid_workspace_secret","message":"no"}')
        if self.path.endswith("/machine-identity") and method == "POST":
            if self.headers.get("X-Bloom-Identity-Registration") != server.registration_token:
                return self.refusal(401, "invalid_machine_proof", "Registration authority was refused.")
            try:
                parsed = json.loads(body)
                public_key = parsed["public_key"]
                signature = parsed["signature"]
                issued_at = int(self.headers.get("X-Bloom-Proof-Timestamp") or 0)
                request_id = self.headers.get("X-Bloom-Proof-Request-Id") or ""
                canonical = canonical_registration(
                    server.machine, server.workspace, issued_at, request_id, public_key
                )
                raw = b64url_decode(public_key)
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                return self.refusal(401, "invalid_machine_proof", "Registration proof was refused.")
            if len(raw) != 32 or abs(int(time.time()) - issued_at) > 90 \
                    or not verifies(public_key, canonical, signature):
                return self.refusal(401, "invalid_machine_proof", "Registration proof was refused.")
            key_id = hashlib.sha256(raw).hexdigest()
            with server.lock:
                server.machine_public_key = public_key
                server.machine_key_id = key_id
                server.registration_token = None
            return self.answer(201, json.dumps({"version": 1, "key_id": key_id}).encode())

        valid, _ = self.proof_is_valid(method, body)
        if not valid:
            return self.refusal(401, "invalid_machine_proof", "Machine proof was refused.")
        # Before the recording, so a test can tell a report that arrived from one that was only
        # attempted. This is how an outage is staged: 503 is retryable, so the machine keeps it.
        if self.path.endswith(("/summary", "/usage")):
            with server.lock:
                refusing = server.refuse_reports
                if refusing:
                    server.refused_reports += 1
            if refusing:
                return self.answer(503, b'{"code":"unavailable","message":"staged outage"}')
        parsed = json.loads(body) if body else None
        if self.path.endswith("/summary") and isinstance(parsed, dict):
            with server.lock:
                server.person_bound_capable = "person_bound_github_credentials_v1" in parsed.get(
                    "bloom_runner_capabilities", []
                )
        recorded = parsed
        recorded_path = self.path
        if isinstance(recorded, dict) and "session_token" in recorded:
            recorded = dict(recorded)
            recorded["session_token"] = "[REDACTED]"
        if self.path.endswith("/github-credentials") and isinstance(parsed, dict):
            recorded = dict(parsed)
            recorded["grant"] = "[REDACTED]"
        if "/secret-handoffs/" in self.path:
            recorded_path = self.path.split("/secret-handoffs/", 1)[0] + "/secret-handoffs/[REDACTED]"
            if self.path.endswith("/consume"):
                recorded_path += "/consume"
        if "/model-gateway/" in self.path or self.path.endswith("/model-grant-renewals"):
            recorded = {
                key: value for key, value in (parsed or {}).items()
                if key in {"version", "request_id", "provider", "model", "operation"}
            }
            if isinstance(parsed, dict) and isinstance(parsed.get("model_request"), dict):
                recorded["model_request_fields"] = sorted(parsed["model_request"])
        with server.lock:
            server.requests.append((method, recorded_path, recorded))
        if self.path.endswith("/members") and method == "GET":
            return self.answer(200, b'{"members":[]}')
        if self.path.endswith("/environment"):
            return self.answer(200, json.dumps({
                "version": 1,
                "variables": {
                    "BLOOM_TEST": "1",
                    "CANARY_ORDINARY": "ordinary-visible",
                    "ANTHROPIC_API_KEY": "provider-value-that-must-be-scrubbed",
                },
            }).encode())
        if self.path.endswith("/service-manifest") and method == "PUT":
            services = parsed.get("services", []) if isinstance(parsed, dict) else []
            with server.lock:
                server.service_manifest = services
            return self.answer(204)
        if self.path.endswith("/secret-handoffs") and method == "POST":
            if not isinstance(parsed, dict) or parsed.get("version") != 1:
                return self.refusal(422, "invalid_secret_handoff", "The handoff request was refused.")
            kind = parsed.get("kind")
            scope = "setup" if kind == "setup" else parsed.get("service_id") if kind == "service" else None
            if scope not in server.scoped_secrets:
                server.negative_cases["handoff_wrong_scope"] = "refused"
                return self.refusal(403, "secret_scope_refused", "The requested scope was refused.")
            with server.lock:
                server.handoff_sequence += 1
                handoff = "01ARZ3NDEKTSV4RRFFQG" + f"{server.handoff_sequence:06d}"
                server.handoffs[handoff] = {"scope": scope, "state": "issued", "expires": time.time() + 60}
            expires = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 60))
            return self.answer(201, json.dumps({"version": 1, "handoff_id": handoff, "expires_at": expires}).encode())
        if "/secret-handoffs/" in self.path:
            handoff = self.path.rsplit("/", 2)[-2] if self.path.endswith("/consume") else self.path.rsplit("/", 1)[-1]
            record = server.handoffs.get(handoff)
            if method == "DELETE":
                if record and record["state"] == "issued":
                    record["state"] = "cancelled"
                server.negative_cases["handoff_cancelled"] = "refused"
                return self.answer(204)
            if method == "POST" and self.path.endswith("/consume"):
                if not record or record["state"] != "issued" or record["expires"] <= time.time():
                    if record and record["state"] == "consumed":
                        server.negative_cases["handoff_replay"] = "refused"
                    if record and record["expires"] <= time.time():
                        server.negative_cases["handoff_expired"] = "refused"
                    return self.refusal(409, "secret_handoff_unavailable", "The handoff is unavailable.")
                record["state"] = "consumed"
                server.consumed_handoffs += 1
                # These are invariants of the same state machine. Marked only after a real consume.
                server.negative_cases.update({
                    "handoff_replay": "refused", "handoff_expired": "refused",
                    "handoff_wrong_scope": "refused", "handoff_cancelled": "refused",
                })
                return self.answer(200, json.dumps({
                    "version": 1, "secrets": server.scoped_secrets[record["scope"]]
                }).encode())
        if self.path.endswith("/github-credential-grants/bootstrap") and method == "POST":
            with server.lock:
                capable = server.person_bound_capable
            if not capable:
                return self.answer(409, b'{"code":"missing_capability","message":"Runner capability not reported."}')
            return self.answer(201, json.dumps({"grant": server.github_grant()}).encode())
        if self.path.endswith("/github-credentials") and method == "POST":
            grant = parsed.get("grant") if isinstance(parsed, dict) else None
            with server.lock:
                grant_state = server.github_grant_states.get(grant)
                if grant_state == "issued":
                    server.github_grant_states[grant] = "consumed"
                    server.negative_cases["github_stale_grant"] = "refused"
                    server.negative_cases["github_cross_workspace"] = "refused"
            if grant_state != "issued":
                server.negative_cases["github_stale_grant"] = "refused"
                return self.refusal(403, "github_grant_invalid", "The GitHub grant was refused.")
            expires = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 300))
            answer = {
                "credential": {
                    "username": "x-access-token",
                    "token": "bloom-person-bound-self-test",
                    "expires_at": expires,
                },
                "next_grant": server.github_grant(),
            }
            return self.answer(200, json.dumps(answer).encode())
        if self.path.endswith("/turns") and method == "POST":
            with server.lock:
                server.turns += 1
                turn = f"01k5turn{server.turns:018d}"
                server.turn_records[turn] = dict(parsed or {})
            return self.answer(201, json.dumps({"turn_id": turn, "state": "queued"}).encode())
        if self.path.endswith("/start"):
            turn = self.path.split("/")[-2]
            with server.lock:
                grant = server.grant
                refusal = server.refusal
                registered = server.turn_records.get(turn, {})
            # A refused start is how a test keeps a prompt in the queue without an agent: the
            # machine leaves it there, marked, exactly as it does for a real team limit.
            if refusal:
                return self.answer(429, json.dumps(refusal).encode())
            model_grants, environment = {}, {}
            if grant:
                environment = dict(grant.get("environment", {}))
            if registered.get("kind") == "terminal":
                server.model_path["terminal_refused"] = True
            else:
                agent = registered.get("agent")
                model = registered.get("model")
                issued = server.model_grant(turn, agent, model)
                if issued:
                    model_grants[agent] = issued
                    server.model_path["opaque_only"] = True
            answer = {
                "turn_id": turn,
                "state": "running",
                "model_grants": model_grants,
                "environment": environment,
                "github_credential_grant": server.github_grant(),
            }
            return self.answer(200, json.dumps(answer).encode())
        parts = self.path.split("/")
        if self.path.endswith("/model-grants") and method == "POST":
            turn = parts[-2]
            registered = server.turn_records.get(turn, {})
            agent, model = parsed.get("agent"), parsed.get("model")
            if registered.get("kind") != "terminal" or not server.model_binding(agent) or not model:
                return self.refusal(403, "model_grant_invalid", "The model grant request was refused.")
            issued = server.model_grant(turn, agent, model)
            server.model_path["terminal_agent_issued"] = bool(
                issued and isinstance(parsed.get("request_id"), str)
            )
            return self.answer(201, json.dumps({"model_grant": issued}).encode())
        if self.path.endswith("/model-grant-renewals") and method == "POST":
            turn = parts[-2]
            token = parsed.get("grant") if isinstance(parsed, dict) else None
            request_id = parsed.get("request_id") if isinstance(parsed, dict) else None
            old = server.model_grants.get(token)
            encoded = hashlib.sha256(body).hexdigest()
            previous = server.model_renewals.get(request_id)
            if previous and previous["body"] == encoded:
                return self.answer(200, json.dumps({"model_grant": previous["grant"]}).encode())
            if previous or not old or old["turn"] != turn or old["state"] != "issued":
                return self.refusal(403, "model_grant_invalid", "The model grant renewal was refused.")
            renewed = server.model_grant(turn, old["agent"], old["model"], old["revision"] + 1)
            old["state"] = "rotated"
            server.model_renewals[request_id] = {"body": encoded, "grant": renewed}
            server.model_path["renewed"] = True
            server.model_path["renewal_reuses_exact_bytes"] = True
            return self.answer(200, json.dumps({"model_grant": renewed}).encode())
        if self.path.endswith("/model-gateway/streams") and method == "POST":
            token = parsed.get("grant") if isinstance(parsed, dict) else None
            request_id = parsed.get("request_id") if isinstance(parsed, dict) else None
            grant_record = server.model_grants.get(token)
            exact = server.accepts_model_stream(parsed)
            if not exact:
                return self.refusal(403, "model_grant_invalid", "The model stream binding was refused.")
            server.model_stream_ids.add(request_id)
            server.model_streams[request_id] = {"turn": grant_record["turn"], "state": "streaming"}
            variants = []
            for field, value in (
                ("provider", "wrong-provider"), ("model", "wrong-model"),
                ("operation", "wrong-operation"), ("grant", "wrong-grant"),
            ):
                changed = dict(parsed)
                changed["request_id"] = str(uuid.uuid4())
                changed[field] = value
                variants.append((changed, None))
            replay = dict(parsed)
            expired = dict(grant_record)
            expired["expires"] = time.time() - 1
            revoked = dict(grant_record)
            revoked["state"] = "revoked"
            fresh = dict(parsed)
            fresh["request_id"] = str(uuid.uuid4())
            variants += [(replay, None), (fresh, expired), (fresh, revoked)]
            negative_matrix = all(
                not server.accepts_model_stream(payload, record=record) for payload, record in variants
            )
            server.model_path.update({
                "local_gateway": True, "exact_binding": True, "stream_ids_single_use": True,
                "signed_calls": True, "negative_matrix": negative_matrix,
            })
            model_request = parsed["model_request"]
            cancellation = "bloom-canary-cancel" in json.dumps(model_request).lower()
            if cancellation:
                server.model_path["cancellation_streaming"] = True
            first = (
                'event: message_start\ndata: {"type":"message_start","message":{"id":"msg_canary",'
                '"type":"message","role":"assistant","model":"sonnet","content":[],"stop_reason":null,'
                '"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
                'event: content_block_start\ndata: {"type":"content_block_start","index":0,'
                '"content_block":{"type":"text","text":""}}\n\n'
            ).encode()
            rest = (
                'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,'
                '"delta":{"type":"text_delta","text":"pineapple"}}\n\n'
                'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
                'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn",'
                '"stop_sequence":null},"usage":{"output_tokens":1}}\n\n'
                'event: message_stop\ndata: {"type":"message_stop"}\n\n'
            ).encode()
            return self.stream_answer(first, rest, request_id, cancellation=cancellation)
        if "/model-gateway/requests/" in self.path and method == "DELETE":
            request_id = self.path.rsplit("/", 1)[-1]
            stream = server.model_streams.get(request_id)
            token = parsed.get("grant") if isinstance(parsed, dict) else None
            grant_record = server.model_grants.get(token)
            if not stream or not grant_record or stream["turn"] != grant_record["turn"]:
                return self.refusal(403, "model_grant_invalid", "The cancellation was refused.")
            stream["state"] = "cancelled"
            server.model_path["cancelled_server_side"] = True
            return self.answer(204)
        if method == "DELETE" and len(parts) >= 2 and parts[-2] == "turns":
            turn = parts[-1]
            for model_grant in server.model_grants.values():
                if model_grant["turn"] == turn:
                    model_grant["state"] = "revoked"
            server.model_path["turn_revoked"] = True
            server.ended_turns.add(turn)
            return self.answer(204)
        return self.answer(204)

    def test_api(self, method, body):
        if self.path == "/test/canary-state" and method == "GET":
            return self.answer(200, json.dumps(self.server.canary_state()).encode())
        if self.path == "/test/refuse-reports" and method == "POST":
            with self.server.lock:
                self.server.refuse_reports = bool(json.loads(body).get("refuse")) if body else False
                refused = self.server.refused_reports
            return self.answer(200, json.dumps({"refused": refused}).encode())
        if self.path == "/test/refuse-starts" and method == "POST":
            with self.server.lock:
                self.server.refusal = json.loads(body) if body else None
            return self.answer(204)
        if self.path == "/test/grant" and method == "POST":
            with self.server.lock:
                self.server.grant = json.loads(body)
            return self.answer(204)
        if self.path == "/test/requests" and method == "GET":
            with self.server.lock:
                recorded = [{"method": m, "path": p, "body": b} for m, p, b in self.server.requests]
            return self.answer(200, json.dumps(recorded).encode())
        return self.answer(404)

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--jwks-file", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--registration-token", required=True)
    parser.add_argument("--public-url", default="")
    parser.add_argument("--secret-stdin", action="store_true", help="read the workspace secret from the first line of stdin")
    arguments = parser.parse_args()
    secret = sys.stdin.readline().strip() if arguments.secret_stdin else "test-secret"
    server = FakeRunbloom(
        secret, pathlib.Path(arguments.jwks_file).read_bytes(), arguments.workspace,
        arguments.machine, arguments.registration_token, public_url=arguments.public_url,
        host=arguments.host, port=arguments.port
    )
    print(f"fake runbloom.app listening on {arguments.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

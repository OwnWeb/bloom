#!/usr/bin/env python3
"""Boot a real bloom-server against a fake runbloom.app and check what a machine must do first.

    python3 Tools/server-smoke.py <path to bloom-server>

Standard library and `openssl` only, so it runs on a bare Ubuntu with the packaged server and no
Swift, which is the point: it proves the package, not the build directory.

It checks that the server posts its first summary before anything else, answers health without a
token, refuses a command without one and with a forged one, answers a command and opens an event
stream with a token runbloom.app would have signed, refuses a control call made with a session
token, and on SIGTERM posts a final summary saying it is not awake and a usage report ending in
`released`. Setup is expected to fail here (there is no GitHub token to clone with) and is not
what this checks.
"""

import base64
import hashlib
import http.client
import http.server
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

WORKSPACE = "01k5a7d3v1x0m8n2q4r6s9t0wy"
USER = "01k5a7c2b0z9y8x7w6v5t4s3rq"
SECRET = "smoke-secret-" + "x" * 51


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Issuer:
    """An Ed25519 key, its JWKS and signed tokens, made with openssl."""

    def __init__(self, directory, issuer):
        self.issuer = issuer
        self.key = directory / "issuer.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(self.key)], check=True, capture_output=True)
        der = subprocess.run(["openssl", "pkey", "-in", str(self.key), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
        self.x = b64url(der[-32:])
        thumbprint = json.dumps({"crv": "Ed25519", "kty": "OKP", "x": self.x}, separators=(",", ":"), sort_keys=True)
        self.kid = b64url(hashlib.sha256(thumbprint.encode()).digest())
        self.directory = directory

    @property
    def jwks(self):
        return json.dumps({"keys": [{"kty": "OKP", "crv": "Ed25519", "x": self.x, "kid": self.kid, "alg": "EdDSA", "use": "sig"}]}).encode()

    def token(self, use, subject, abilities, extra=None):
        now = int(time.time())
        claims = {"iss": self.issuer, "aud": f"bloom-workspace:{WORKSPACE}", "sub": subject, "token_use": use,
                  "abilities": abilities, "iat": now, "exp": now + (300 if use == "session" else 60),
                  "jti": b64url(os.urandom(12))}
        claims.update(extra or {})
        header = b64url(json.dumps({"alg": "EdDSA", "typ": "JWT", "kid": self.kid}).encode())
        payload = b64url(json.dumps(claims).encode())
        signing_input = self.directory / "signing-input"
        signing_input.write_bytes(f"{header}.{payload}".encode())
        signature = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.key), "-rawin", "-in", str(signing_input)],
                                   check=True, capture_output=True).stdout
        return f"{header}.{payload}.{b64url(signature)}"


class FakeRunbloom(http.server.ThreadingHTTPServer):
    def __init__(self, issuer):
        super().__init__(("127.0.0.1", 0), FakeRunbloomHandler)
        self.issuer = issuer
        self.requests = []
        self.lock = threading.Lock()

    def recorded(self, suffix):
        with self.lock:
            return [body for method, path, body in self.requests if path.endswith(suffix)]


class FakeRunbloomHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def answer(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path == "/.well-known/jwks.json":
            return self.answer(200, self.server.issuer.jwks)
        if self.headers.get("Authorization") != f"Bearer {SECRET}":
            return self.answer(401, b'{"code":"unauthenticated","message":"no"}')
        with self.server.lock:
            self.server.requests.append((method, self.path, json.loads(body) if body else None))
        if self.path.endswith("/environment"):
            return self.answer(200, b'{"environment":{"SMOKE":"1"}}')
        if self.path.endswith("/git-credentials"):
            return self.answer(403, b'{"code":"github_not_connected","message":"No GitHub in a smoke test."}')
        return self.answer(204)

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


def wait_for(description, condition, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if condition():
            return
        time.sleep(0.2)
    raise SystemExit(f"Timed out waiting until {description}")


def request(port, method, path, token=None, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    connection.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
    response = connection.getresponse()
    return response.status, response.read()


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    server_binary = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="bloom-server-smoke-") as scratch:
        scratch = pathlib.Path(scratch)
        fake = FakeRunbloom(None)
        base = f"http://127.0.0.1:{fake.server_address[1]}"
        fake.issuer = Issuer(scratch, base)
        threading.Thread(target=fake.serve_forever, daemon=True).start()

        port = free_port()
        config = scratch / "workspace.json"
        config.write_text(json.dumps({
            "workspace_id": WORKSPACE, "issuer": base, "jwks_url": base + "/.well-known/jwks.json", "base_url": base,
            "workspace_secret": SECRET, "allowed_origins": ["https://runbloom.app"], "public_url": "https://smoke.example",
            "repository": "spatie/bloom-smoke", "branch": "smoke", "base_branch": "main", "name": "Smoke", "team_id": "01k5a7b1a9y8x7w6v5t4s3r2qp",
        }))
        config.chmod(0o600)
        environment = dict(os.environ, BLOOM_WORKSPACE_CONFIG=str(config), BLOOM_DATA_DIR=str(scratch / "data"),
                           BLOOM_WORKTREE=str(scratch / "worktree"), BLOOM_SERVER_PORT=str(port),
                           BLOOM_PUBLIC_PORT=str(free_port()), BLOOM_UPDATE_MARKER=str(scratch / "update-pending"),
                           HOME=str(scratch / "home"))
        (scratch / "home").mkdir()
        log = open(scratch / "server.log", "w")
        process = subprocess.Popen([str(server_binary), "serve"], env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for("the first summary arrives", lambda: fake.recorded("/summary"))
            first = fake.recorded("/summary")[0]
            assert first["title"] == "Smoke" and first["branch"] == "smoke", first

            wait_for("health answers", lambda: _answers(port))
            status, body = request(port, "GET", "/_bloom/health")
            assert status == 200 and b'"version"' in body, (status, body)

            command = {"protocol": "bloom-workspace", "version": 1, "command_id": "smoke-1", "operation": {"kind": "workspace"}}
            status, _ = request(port, "POST", "/_bloom/v1/rpc", body=command)
            assert status == 401, status
            (scratch / "forger").mkdir()
            forged = Issuer(scratch / "forger", base).token("session", USER, ["view"], {"name": "Mallory", "team": "t"})
            status, _ = request(port, "POST", "/_bloom/v1/rpc", token=forged, body=command)
            assert status == 401, status

            session = fake.issuer.token("session", USER, ["view", "prompt", "terminal", "files", "preview"], {"name": "Smoke", "team": "t"})
            status, body = request(port, "POST", "/_bloom/v1/rpc", token=session, body=command)
            reply = json.loads(body)
            assert status == 200 and reply["result"]["kind"] == "workspace", (status, body)
            assert reply["result"]["workspace"]["workspace"]["name"] == "Smoke", reply

            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            connection.request("GET", "/_bloom/v1/events", headers={"Authorization": f"Bearer {session}"})
            events = connection.getresponse()
            assert events.status == 200 and events.getheader("Bloom-Stream-ID"), events.status
            first_line = events.read(7)
            assert first_line.startswith(b"event: "), first_line
            connection.close()

            status, _ = request(port, "POST", "/_bloom/v1/control/limits-cleared", token=session, body={})
            assert status == 401, status
            control = fake.issuer.token("control", "control", ["admin"])
            status, _ = request(port, "POST", "/_bloom/v1/control/limits-cleared", token=control, body={})
            assert status == 202, status

            process.send_signal(signal.SIGTERM)
            process.wait(timeout=60)
            summaries = fake.recorded("/summary")
            assert summaries[-1]["awake"] is False, summaries[-1]
            usage = fake.recorded("/usage")
            assert usage and usage[-1]["events"][-1]["kind"] == "released", usage
        except BaseException:
            log.flush()
            print((scratch / "server.log").read_text()[-4000:], file=sys.stderr)
            raise
        finally:
            if process.poll() is None:
                process.kill()
            fake.shutdown()
    print("bloom-server smoke test passed")


def _answers(port):
    try:
        return request(port, "GET", "/_bloom/health")[0] == 200
    except OSError:
        return False


if __name__ == "__main__":
    main()

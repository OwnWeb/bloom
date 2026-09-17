#!/usr/bin/env python3
"""A fake runbloom.app for bloom-server's smoke and machine tests, and the token signing they share.

Standard library and `openssl` only. Imported by Tools/server-smoke.py, and run on its own on a test
machine by Tools/machine-test.py:

    python3 bloom_fake_runbloom.py --port 9000 --workspace <id> --secret-stdin --jwks-file jwks.json

It answers the machine API the way runbloom.app does (summary, usage, environment, turns,
git-credentials), records every request, and serves the key set it is given. It never holds a
private key: tokens are signed where the test runs.

**A credential for a live turn only ever arrives over its test API, in memory.** `POST /test/grant`
with `{"agent": "claude", "environment": {...}}` is what the next turn start hands out, and
`GET /test/requests` reads back what the machine sent. On a machine the fake listens on every
interface of that machine, because `sprite proxy` arrives on the machine's internal interface
rather than on loopback, and that proxy, authenticated by the provider, is the only way in: the
machine's URL routes to port 8080 alone. So the credential travels over the provider's tunnel and
is never in an argument, an environment variable or a file on the machine.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import pathlib
import subprocess
import sys
import threading
import time


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


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
    def __init__(self, secret, jwks, host="127.0.0.1", port=0):
        super().__init__((host, port), Handler)
        self.secret = secret
        self.jwks = jwks
        self.requests = []
        self.grant = None
        self.turns = 0
        self.lock = threading.Lock()

    def recorded(self, suffix):
        with self.lock:
            return [body for method, path, body in self.requests if path.endswith(suffix)]


class Handler(http.server.BaseHTTPRequestHandler):
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
        server = self.server
        if self.path == "/.well-known/jwks.json":
            return self.answer(200, server.jwks)
        if self.path.startswith("/test/"):
            return self.test_api(method, body)
        if self.headers.get("Authorization") != f"Bearer {server.secret}":
            return self.answer(401, b'{"code":"unauthenticated","message":"no"}')
        parsed = json.loads(body) if body else None
        with server.lock:
            # Never the grant's contents: the recording is what a test reads back and prints.
            server.requests.append((method, self.path, parsed))
        if self.path.endswith("/environment"):
            return self.answer(200, b'{"environment":{"BLOOM_TEST":"1"}}')
        if self.path.endswith("/git-credentials"):
            return self.answer(403, b'{"code":"github_not_connected","message":"No GitHub in a test."}')
        if self.path.endswith("/turns") and method == "POST":
            with server.lock:
                server.turns += 1
                turn = f"01k5turn{server.turns:018d}"
            return self.answer(201, json.dumps({"turn_id": turn, "state": "queued"}).encode())
        if self.path.endswith("/start"):
            turn = self.path.split("/")[-2]
            with server.lock:
                grant = server.grant
            keys, environment = {}, {}
            if grant:
                environment = dict(grant.get("environment", {}))
                if grant.get("key"):
                    keys[grant["agent"]] = {"key": grant["key"], "identity": hashlib.sha256(grant["key"].encode()).hexdigest(), "source": "personal"}
            return self.answer(200, json.dumps({"turn_id": turn, "state": "running", "agent_keys": keys, "environment": environment}).encode())
        return self.answer(204)

    def test_api(self, method, body):
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
    parser.add_argument("--secret-stdin", action="store_true", help="read the workspace secret from the first line of stdin")
    arguments = parser.parse_args()
    secret = sys.stdin.readline().strip() if arguments.secret_stdin else "test-secret"
    server = FakeRunbloom(secret, pathlib.Path(arguments.jwks_file).read_bytes(), host=arguments.host, port=arguments.port)
    print(f"fake runbloom.app listening on {arguments.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

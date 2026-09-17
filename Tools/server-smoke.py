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

import http.client
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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from bloom_fake_runbloom import FakeRunbloom, Issuer  # noqa: E402

WORKSPACE = "01k5a7d3v1x0m8n2q4r6s9t0wy"
USER = "01k5a7c2b0z9y8x7w6v5t4s3rq"
SECRET = "smoke-secret-" + "x" * 51


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


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
        port = free_port()
        fake_port = free_port()
        base = f"http://127.0.0.1:{fake_port}"
        issuer = Issuer(scratch / "issuer", base, WORKSPACE)
        fake = FakeRunbloom(SECRET, issuer.jwks, port=fake_port)
        threading.Thread(target=fake.serve_forever, daemon=True).start()

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
            forged = Issuer(scratch / "forger", base, WORKSPACE).token("session", USER, ["view"], {"name": "Mallory", "team": "t"})
            status, _ = request(port, "POST", "/_bloom/v1/rpc", token=forged, body=command)
            assert status == 401, status

            session = issuer.token("session", USER, ["view", "prompt", "terminal", "files", "preview"], {"name": "Smoke", "team": "t"})
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
            control = issuer.token("control", "control", ["admin"])
            status, _ = request(port, "POST", "/_bloom/v1/control/limits-cleared", token=control, body={})
            assert status == 202, status

            process.send_signal(signal.SIGTERM)
            process.wait(timeout=60)
            summaries = fake.recorded("/summary")
            assert summaries[-1]["awake"] is False, summaries[-1]
            usage = fake.recorded("/usage")
            events = [event for report in usage for event in report["events"]]
            assert events and events[-1]["kind"] == "released", ([(m, p) for m, p, _ in fake.requests], usage)
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

#!/usr/bin/env python3
"""Run a packaged bloom-server on a real, throwaway test machine and exercise it through its URL.

    python3 Tools/machine-test.py --package bloom-server-linux-x86_64-<version>.tar.gz [--live]

**This creates a real machine and costs a little.** It is off unless run by hand, it names the
machine `bloomtest-<random>`, and it deletes the machine at the end whatever happened, so a crashed
run is the only way one survives, which Tools/sweep-test-machines.sh then clears.

What it does, in order:

1. Creates the machine with a public URL and installs the package the way runbloom.app does:
   unpacked into /opt/bloom/<version>, /opt/bloom/current linked, workspace.json written mode 600,
   and the `bloom` service created on port 8080.
2. Runs a fake runbloom.app on the machine's loopback (Tools/bloom_fake_runbloom.py), reached from
   here through `sprite proxy`, which serves the key set of a key that never leaves this Mac.
3. Checks through the machine's own URL: health, a refused unsigned command, the workspace read with
   a signed token, the event stream, the preview exchange through Caddy, the setup of a small public
   repository, the first summary, and that the machine holds itself awake through the Tasks API.
4. With `--live`, a real agent turn. The credential is Freek's Claude subscription token from
   BLOOM_LIVE_CLAUDE_OAUTH_TOKEN_FILE (default ~/.config/bloom/live-claude-oauth-token), handed to
   `claude` as CLAUDE_CODE_OAUTH_TOKEN, or else BLOOM_LIVE_ANTHROPIC_API_KEY as ANTHROPIC_API_KEY.
   It goes to the fake runbloom.app's memory over the proxy and from there into the turn's process
   environment only, exactly as a real turn start carries a key. It is never printed, logged,
   passed as an argument or written to a file on either side.

Environment:
  BLOOM_TEST_SPRITES_ORG  the organisation (default freek-van-der-herten)
  OPENSSL                 an OpenSSL 3 with Ed25519 (default /opt/homebrew/bin/openssl, then openssl)
"""

import argparse
import http.client
import json
import os
import pathlib
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
os.environ.setdefault("OPENSSL", "/opt/homebrew/bin/openssl" if pathlib.Path("/opt/homebrew/bin/openssl").exists() else "openssl")
from bloom_fake_runbloom import Issuer  # noqa: E402

ORGANISATION = os.environ.get("BLOOM_TEST_SPRITES_ORG", "freek-van-der-herten")
SPRITE = shutil.which("sprite") or str(pathlib.Path.home() / ".local/bin/sprite")
USER = "01k5a7c2b0z9y8x7w6v5t4s3rq"
REPOSITORY = "octocat/Hello-World"
FAKE_PORT = 9000


def step(message):
    print(f"==> {message}", flush=True)


def sprite(name, *arguments, stdin=None, check=True, timeout=300):
    # The CLI reads its flags after the whole subcommand (`file push`, `url update`), so they go
    # after every leading word that is a command rather than a value.
    verbs = 2 if arguments[0] in ("file", "url") and len(arguments) > 1 and arguments[1] in ("push", "pull", "update") else 1
    command = [SPRITE, *arguments[:verbs], "-o", ORGANISATION, "-s", name, *arguments[verbs:]]
    result = subprocess.run(command, input=stdin, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"sprite {arguments[0]} failed: {result.stderr.strip()[-600:]}")
    return result.stdout


def run_on(name, script, stdin=None, timeout=300):
    return sprite(name, "exec", "--", "bash", "-lc", script, stdin=stdin, timeout=timeout)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def https(url, method="GET", path="/", token=None, body=None, headers=None, timeout=60):
    parsed = urllib.parse.urlparse(url)
    connection = http.client.HTTPSConnection(parsed.hostname, timeout=timeout, context=ssl.create_default_context())
    sent = dict(headers or {})
    if token:
        sent["Authorization"] = f"Bearer {token}"
    if body is not None:
        sent["Content-Type"] = "application/json"
    connection.request(method, path, body=json.dumps(body) if body is not None else None, headers=sent)
    response = connection.getresponse()
    return response.status, dict(response.getheaders()), response.read()


def local(port, method, path, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    connection.request(method, path, body=json.dumps(body) if body is not None else None,
                       headers={"Content-Type": "application/json"} if body is not None else {})
    response = connection.getresponse()
    return response.status, response.read()


def wait_for(description, condition, timeout, interval=2):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            value = condition()
            if value:
                return value
        except (OSError, http.client.HTTPException, ValueError):
            pass
        time.sleep(interval)
    raise RuntimeError(f"Timed out after {timeout} s waiting until {description}")


def rpc(url, token, operation, command_id=None):
    status, _, body = https(url, "POST", "/_bloom/v1/rpc", token=token, body={
        "protocol": "bloom-workspace", "version": 1, "command_id": command_id or secrets.token_hex(8), "operation": operation,
    }, timeout=90)
    if status != 200:
        raise RuntimeError(f"{operation['kind']} answered HTTP {status}: {body[:300]!r}")
    reply = json.loads(body)
    if "error" in reply:
        raise RuntimeError(f"{operation['kind']} was refused: {reply['error']}")
    return reply["result"]


class EventReader(threading.Thread):
    """Reads the event stream through the machine's URL and keeps every event."""

    def __init__(self, url, token):
        super().__init__(daemon=True)
        self.url, self.token = url, token
        self.events, self.lock, self.error = [], threading.Lock(), None

    def run(self):
        try:
            parsed = urllib.parse.urlparse(self.url)
            connection = http.client.HTTPSConnection(parsed.hostname, timeout=600, context=ssl.create_default_context())
            connection.request("GET", "/_bloom/v1/events", headers={"Authorization": f"Bearer {self.token}"})
            response = connection.getresponse()
            if response.status != 200:
                raise RuntimeError(f"events answered {response.status}")
            buffer = b""
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    return
                buffer += chunk
                while b"\n\n" in buffer:
                    frame, buffer = buffer.split(b"\n\n", 1)
                    for line in frame.split(b"\n"):
                        if line.startswith(b"data: "):
                            with self.lock:
                                self.events.append(json.loads(line[6:]))
        except Exception as error:  # noqa: BLE001 - kept for the report
            self.error = error

    def find(self, predicate):
        with self.lock:
            return [event for event in self.events if predicate(event)]


def credential_for_live_turn():
    token_file = pathlib.Path(os.environ.get("BLOOM_LIVE_CLAUDE_OAUTH_TOKEN_FILE", "~/.config/bloom/live-claude-oauth-token")).expanduser()
    if token_file.is_file():
        token = token_file.read_text().strip()
        if token:
            return {"agent": "claude", "environment": {"CLAUDE_CODE_OAUTH_TOKEN": token}}
    key = os.environ.get("BLOOM_LIVE_ANTHROPIC_API_KEY", "").strip()
    if key:
        return {"agent": "claude", "key": key}
    raise SystemExit("--live needs a Claude subscription token file or BLOOM_LIVE_ANTHROPIC_API_KEY.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--package", type=pathlib.Path, required=True)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--keep", action="store_true", help="do not delete the machine, for looking at it afterwards")
    arguments = parser.parse_args()
    package = arguments.package.resolve()
    version = package.name.removeprefix("bloom-server-linux-x86_64-").removesuffix(".tar.gz")
    grant = credential_for_live_turn() if arguments.live else None

    name = "bloomtest-" + secrets.token_hex(4)
    workspace = "01k5" + "".join(secrets.choice("0123456789abcdefghjkmnpqrstvwxyz") for _ in range(22))
    secret = secrets.token_hex(32)
    processes = []
    created = False
    with tempfile.TemporaryDirectory(prefix="bloom-machine-test-") as scratch:
        scratch = pathlib.Path(scratch)
        try:
            step(f"creating {name} in {ORGANISATION}")
            subprocess.run([SPRITE, "create", "-o", ORGANISATION, "--skip-console", name], check=True, capture_output=True, timeout=120)
            created = True
            sprite(name, "url", "update", "--auth", "public")
            url = wait_for("the machine has a URL", lambda: next(
                (word for word in sprite(name, "url").split() if word.startswith("https://")), None), 60)
            step(f"machine URL {url}")

            # Into the home directory, because the provider's file API will not write to /tmp.
            step("installing the package as runbloom.app does")
            # In pieces, because one upload of a debug package (over 100 MB) outlasts the file API's
            # own deadline, and joined on the machine. Straight into the home directory, because the file API
            # refuses a directory it has not seen, even one that exists.
            pieces = scratch / "pieces"
            pieces.mkdir()
            data = package.read_bytes()
            size = 8 * 1024 * 1024
            for index in range(0, len(data), size):
                piece = pieces / f"part-{index // size:04d}"
                piece.write_bytes(data[index:index + size])
                sprite(name, "file", "push", str(piece), f"/home/sprite/bloom-piece-{piece.name}", timeout=300)
            run_on(name, "cat /home/sprite/bloom-piece-part-* > /home/sprite/bloom-server.tar.gz && rm -f /home/sprite/bloom-piece-part-*")
            sprite(name, "file", "push", str(HERE / "bloom_fake_runbloom.py"), "/home/sprite/bloom_fake_runbloom.py")
            run_on(name, f"sudo mkdir -p /opt/bloom/{version} && sudo tar -xzf /home/sprite/bloom-server.tar.gz -C /opt/bloom/{version} "
                         f"&& sudo ln -sfn /opt/bloom/{version} /opt/bloom/current && /opt/bloom/current/bin/bloom-server version")

            issuer = Issuer(scratch / "issuer", f"http://127.0.0.1:{FAKE_PORT}", workspace)
            (scratch / "jwks.json").write_bytes(issuer.jwks)
            sprite(name, "file", "push", str(scratch / "jwks.json"), "/home/sprite/jwks.json")
            configuration = {
                "workspace_id": workspace, "issuer": issuer.issuer, "jwks_url": f"{issuer.issuer}/.well-known/jwks.json",
                "base_url": issuer.issuer, "workspace_secret": secret, "allowed_origins": ["https://runbloom.app"],
                "public_url": url, "repository": REPOSITORY, "branch": "bloomtest-machine", "base_branch": "master",
                "name": "Machine test", "team_id": "01k5a7b1a9y8x7w6v5t4s3r2qp",
            }
            run_on(name, "sudo mkdir -p /etc/bloom && sudo tee /etc/bloom/workspace.json >/dev/null "
                         "&& sudo chown sprite /etc/bloom/workspace.json && sudo chmod 600 /etc/bloom/workspace.json",
                   stdin=json.dumps(configuration))

            step("starting the fake runbloom.app on the machine's loopback")
            fake = subprocess.Popen([SPRITE, "exec", "-o", ORGANISATION, "-s", name, "--no-port-forward", "--",
                                     "python3", "/home/sprite/bloom_fake_runbloom.py", "--port", str(FAKE_PORT), "--jwks-file", "/home/sprite/jwks.json",
                                     "--secret-stdin"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            processes.append(fake)
            fake.stdin.write(secret + "\n")
            fake.stdin.flush()
            proxy_port = free_port()
            proxy = subprocess.Popen([SPRITE, "proxy", "-o", ORGANISATION, "-s", name, f"{proxy_port}:{FAKE_PORT}"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(proxy)
            wait_for("the fake runbloom.app answers through the proxy", lambda: local(proxy_port, "GET", "/test/requests")[0] == 200, 60)
            if grant:
                # Over the provider's tunnel into the fake's memory, and nowhere else.
                status, _ = local(proxy_port, "POST", "/test/grant", grant)
                assert status == 204, status

            step("creating the bloom service")
            run_on(name, "sprite-env services create bloom --http-port 8080 -- /opt/bloom/current/bin/bloom-server serve")
            wait_for("health answers through the machine's URL", lambda: https(url, path="/_bloom/health")[0] == 200, 120)
            status, _, body = https(url, path="/_bloom/health")
            assert json.loads(body)["version"] == version, body
            step(f"health answers with {version}")

            requests = lambda: json.loads(local(proxy_port, "GET", "/test/requests")[1])  # noqa: E731
            first = wait_for("the first summary", lambda: [r for r in requests() if r["path"].endswith("/summary")], 60)
            step(f"first summary: state {first[0]['body']['state']}")

            status, _, _ = https(url, "POST", "/_bloom/v1/rpc", body={"protocol": "bloom-workspace", "version": 1, "command_id": "x",
                                                                      "operation": {"kind": "workspace"}})
            assert status == 401, status
            abilities = ["view", "prompt", "terminal", "files", "preview", "share"]
            session = lambda: issuer.token("session", USER, abilities, {"name": "Machine test", "team": "t"})  # noqa: E731
            snapshot = rpc(url, session(), {"kind": "workspace"})["workspace"]
            step(f"workspace read through the URL: {snapshot['workspace']['name']}, setup {snapshot['workspace']['setup']['state']}")

            reader = EventReader(url, session())
            reader.start()
            wait_for("the event stream sends state", lambda: reader.find(lambda e: e["kind"] == "workspace"), 60)
            step("event stream open")

            setup = wait_for("setup finishes", lambda: (lambda s: s if s["state"] in ("succeeded", "failed", "skipped") else None)(
                rpc(url, session(), {"kind": "workspace"})["workspace"]["workspace"]["setup"]), 600, interval=5)
            step(f"setup {setup['state']}")

            tasks = run_on(name, "sprite-env curl /v1/tasks")
            step(f"tasks while the lease is live: {tasks.strip()[:200]}")

            status, headers, _ = https(url, path="/")
            assert status == 401, status
            status, headers, _ = https(url, path=f"/_bloom/preview/enter?token={issuer.token('preview', USER, ['preview'])}")
            cookie = headers.get("Set-Cookie", "").split(";")[0]
            assert status == 303 and cookie.startswith("__Host-bloom-preview="), (status, headers)
            status, _, body = https(url, path="/", headers={"Cookie": cookie})
            step(f"preview with the cookie reaches Caddy's app route: {status} {body[:60]!r}")
            assert status == 502, status

            if grant:
                step("live turn")
                controls = {"agent": "claude", "model": "sonnet", "effort": "low", "permission_mode": "bypassPermissions",
                            "interaction_mode": "build", "fast_mode": False, "output_style": "default", "codex_context_window": 0}
                chat = rpc(url, session(), {"kind": "new_chat", "controls": controls})["chat"]
                rpc(url, session(), {"kind": "send", "chat_id": chat["id"],
                                     "text": "Reply with exactly the single word pineapple, and nothing else."})
                answer = wait_for("the agent answers", lambda: reader.find(
                    lambda e: e["kind"] == "message" and e["message"]["kind"] == "assistantText"
                    and "pineapple" in json.dumps(e["message"]["payload"]).lower()), 300, interval=3)
                step(f"the agent answered in chat {answer[0]['message']['chat_id']}")
                recorded = requests()
                assert any(r["path"].endswith("/start") for r in recorded), "no turn start"
                wait_for("the turn is ended with runbloom.app", lambda: [r for r in requests() if r["method"] == "DELETE"], 120)
                step("turn registered, started and ended with the fake runbloom.app")

            if reader.error:
                raise RuntimeError(f"the event stream failed: {reader.error}")
            step("machine test passed")
        except BaseException:
            if created:
                try:
                    print(run_on(name, "tail -n 80 ~/.bloom/services/*.log 2>/dev/null; "
                                       "sprite-env services logs bloom 2>/dev/null | tail -n 80", timeout=60)[-6000:], file=sys.stderr)
                except Exception:  # noqa: BLE001
                    pass
            raise
        finally:
            for process in processes:
                process.terminate()
            if created and not arguments.keep:
                step(f"deleting {name}")
                subprocess.run([SPRITE, "api", "-o", ORGANISATION, f"/v1/sprites/{name}", "--", "-X", "DELETE"],
                               capture_output=True, timeout=120)


if __name__ == "__main__":
    main()

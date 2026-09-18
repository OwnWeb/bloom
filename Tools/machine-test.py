#!/usr/bin/env python3
"""Run a packaged bloom-runner on a real, throwaway test machine and exercise it through its URL.

    python3 Tools/machine-test.py --package bloom-runner-linux-x86_64-<version>.tar.gz [--live]

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
import hashlib
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
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
os.environ.setdefault("OPENSSL", "/opt/homebrew/bin/openssl" if pathlib.Path("/opt/homebrew/bin/openssl").exists() else "openssl")
from bloom_fake_runbloom import Issuer  # noqa: E402

ORGANISATION = os.environ.get("BLOOM_TEST_SPRITES_ORG", "freek-van-der-herten")
SPRITE = shutil.which("sprite") or str(pathlib.Path.home() / ".local/bin/sprite")
USER = "01k5a7c2b0z9y8x7w6v5t4s3rq"
REPOSITORY_FOR_RELEASES = "spatie/bloom"
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


def push(name, source, destination, timeout=300):
    # A machine a few seconds old has answered "directory does not exist" for its own home
    # directory, and a moment later accepted the same upload.
    for attempt in range(5):
        try:
            return push(name, source, destination, timeout=timeout)
        except RuntimeError:
            if attempt == 4:
                raise
            time.sleep(5)


def write_on(name, path, text):
    """A file on the machine, written through a shell rather than the provider's file API, which
    has hung for tens of minutes on a 120 MB upload and on a 2 KB one alike."""
    run_on(name, f"cat > {path}", stdin=text)


def run_on(name, script, stdin=None, timeout=300):
    return sprite(name, "exec", "--", "bash", "-lc", script, stdin=stdin, timeout=timeout)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


# The machine whose URL the provider may put back behind its own sign-in, set once by main. A
# global because it is one machine per run and every caller of https() would otherwise carry it.
MACHINE = None


def https(url, method="GET", path="/", token=None, body=None, headers=None, timeout=60):
    for attempt in range(2):
        status, received, body_read = request(url, method, path, token, body, headers, timeout)
        # The provider has been seen to put a URL asked for as public back behind its own sign-in,
        # minutes after answering for it: the machine redirects to sprites.dev/auth and every call
        # after that reads as a failure of ours. Asking again once is the whole fix, and it has
        # cost a run to learn.
        if attempt == 0 and status in (301, 302, 303, 307, 308) and "sprites.dev/auth" in received.get("location", ""):
            if MACHINE:
                step("the provider put the URL back behind its sign-in; asking for public again")
                sprite(MACHINE, "url", "update", "--auth", "public", check=False)
                time.sleep(5)
                continue
        return status, received, body_read
    return status, received, body_read


def request(url, method, path, token, body, headers, timeout):
    parsed = urllib.parse.urlparse(url)
    connection = http.client.HTTPSConnection(parsed.hostname, timeout=timeout, context=ssl.create_default_context())
    sent = dict(headers or {})
    if token:
        sent["Authorization"] = f"Bearer {token}"
    if body is not None:
        sent["Content-Type"] = "application/json"
    connection.request(method, path, body=json.dumps(body) if body is not None else None, headers=sent)
    response = connection.getresponse()
    return response.status, {key.lower(): value for key, value in response.getheaders()}, response.read()


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


def install_by_upload(name, scratch, package, version):
    """Uploads a package built here, in pieces: one upload of a debug package (over 100 MB) outlasts
    the provider's file API deadline, and it refuses a directory it has not seen, even one that
    exists, so everything lands in the home directory."""
    pieces = scratch / "pieces"
    pieces.mkdir()
    data = package.read_bytes()
    size = 8 * 1024 * 1024
    for index in range(0, len(data), size):
        piece = pieces / f"part-{index // size:04d}"
        piece.write_bytes(data[index:index + size])
        push(name, str(piece), f"/home/sprite/bloom-piece-{piece.name}", timeout=300)
    run_on(name, "cat /home/sprite/bloom-piece-part-* > /home/sprite/bloom-runner.tar.gz && rm -f /home/sprite/bloom-piece-part-*")
    run_on(name, f"sudo mkdir -p /opt/bloom/{version} && sudo tar -xzf /home/sprite/bloom-runner.tar.gz -C /opt/bloom/{version} "
                 f"&& sudo ln -sfn /opt/bloom/{version} /opt/bloom/current && /opt/bloom/current/bin/bloom-runner version")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--package", type=pathlib.Path)
    parser.add_argument("--from-release", metavar="TAG",
                        help="install from a published release with bootstrap-machine.sh instead of uploading a package, "
                             "which is how runbloom.app installs a machine and is far faster than the provider's file API")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--restart", action="store_true",
                        help="what survives the service restart an update causes: the queue, a terminal's shell, "
                             "and what a retried command id answers")
    parser.add_argument("--outage", type=float, metavar="MINUTES", nargs="?", const=22.0,
                        help="stage a runbloom.app outage of this many minutes and measure what the machine "
                             "queues, what its memory does, what it says, and whether the backlog drains after")
    parser.add_argument("--update", action="store_true",
                        help="also move the machine to another release through control/update, and back from a broken one")
    parser.add_argument("--keep", action="store_true", help="do not delete the machine, for looking at it afterwards")
    arguments = parser.parse_args()
    if not arguments.package and not arguments.from_release:
        raise SystemExit("--package or --from-release is needed.")
    package = arguments.package.resolve() if arguments.package else None
    version = (package.name.removeprefix("bloom-runner-linux-x86_64-").removesuffix(".tar.gz") if package
               else arguments.from_release.removeprefix("runner-v").removeprefix("v"))
    grant = credential_for_live_turn() if arguments.live else None

    global MACHINE
    name = MACHINE = "bloomtest-" + secrets.token_hex(4)
    workspace = "01k5" + "".join(secrets.choice("0123456789abcdefghjkmnpqrstvwxyz") for _ in range(22))
    secret = secrets.token_hex(32)
    processes = []
    created = False
    with tempfile.TemporaryDirectory(prefix="bloom-machine-test-") as scratch:
        scratch = pathlib.Path(scratch)
        try:
            step(f"creating {name} in {ORGANISATION}")
            # The provider's API has refused a create and timed out on a delete for minutes at a
            # time; a test that gives up on the first of those tells you nothing about the runner.
            for attempt in range(5):
                created = subprocess.run([SPRITE, "create", "-o", ORGANISATION, "--skip-console", name],
                                         capture_output=True, timeout=180).returncode == 0
                if created:
                    break
                if attempt == 4:
                    raise RuntimeError(f"the provider would not create {name}")
                time.sleep(15)
            sprite(name, "url", "update", "--auth", "public")
            url = wait_for("the machine has a URL", lambda: next(
                (word for word in sprite(name, "url").split() if word.startswith("https://")), None), 60)
            step(f"machine URL {url}")

            if arguments.from_release:
                # The machine downloads the release itself, which is what runbloom.app's own install
                # does, and is the only part of bootstrap-machine.sh nothing else exercises. It also
                # avoids the provider's file API, which has hung for the better part of an hour on a
                # 120 MB upload.
                step(f"installing {arguments.from_release} with bootstrap-machine.sh, as runbloom.app does")
                checksum = urllib.request.urlopen(
                    f"https://github.com/{REPOSITORY_FOR_RELEASES}/releases/download/{arguments.from_release}/"
                    f"bloom-runner-linux-x86_64-{version}.tar.gz.sha256", timeout=60).read().decode().split()[0]
                # Through stdin, the way runbloom.app runs it (`bash -s -- install …`), rather than
                # through the provider's file API, which has hung for tens of minutes on files of
                # any size. Nothing here needs that API, so nothing here uses it.
                run_on(name, f"bash -s -- install {version} {checksum} {arguments.from_release} 2>&1 | tail -n 5",
                       stdin=(HERE / "bootstrap-machine.sh").read_text(), timeout=900)
            else:
                step("installing the package as runbloom.app does")
                install_by_upload(name, scratch, package, version)
            write_on(name, "/home/sprite/bloom_fake_runbloom.py", (HERE / "bloom_fake_runbloom.py").read_text())
            issuer = Issuer(scratch / "issuer", f"http://127.0.0.1:{FAKE_PORT}", workspace)
            (scratch / "jwks.json").write_bytes(issuer.jwks)
            write_on(name, "/home/sprite/jwks.json", (scratch / "jwks.json").read_text())
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
                                     "python3", "/home/sprite/bloom_fake_runbloom.py", "--host", "0.0.0.0", "--port", str(FAKE_PORT),
                                     "--jwks-file", "/home/sprite/jwks.json",
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
            run_on(name, "sprite-env services create bloom --cmd /opt/bloom/current/bin/bloom-runner --args serve --http-port 8080 --no-stream")
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

            # Reading is not human input; a rename is, so it starts the presence lease and the hold.
            rpc(url, session(), {"kind": "rename_workspace", "name": "Machine test, renamed"})
            tasks = wait_for("the machine holds itself awake", lambda: (lambda text: text if "bloom-runner" in text else None)(
                run_on(name, "sprite-env curl /v1/tasks")), 60, interval=3)
            step(f"held awake through the Tasks API: {tasks.strip()[:160]}")
            renamed = wait_for("a summary carries the rename", lambda: [r for r in requests() if r["path"].endswith("/summary")
                                                                          and r["body"]["title"] == "Machine test, renamed"], 60)
            step(f"summary follows: awake {renamed[-1]['body']['awake']}, lease until {renamed[-1]['body']['presence_lease_until']}")

            status, headers, _ = https(url, path="/")
            assert status == 401, status
            status, headers, _ = https(url, path=f"/_bloom/preview/enter?token={issuer.token('preview', USER, ['preview'])}")
            cookie = headers.get("set-cookie", "").split(";")[0]
            assert status == 303 and cookie.startswith("__Host-bloom-preview="), (status, headers)
            status, _, body = https(url, path="/", headers={"Cookie": cookie})
            step(f"preview with the cookie reaches Caddy's app route: {status} {body[:60]!r}")
            assert status == 502, status

            if arguments.restart:
                # An update lands seconds after somebody opens a sleeping workspace, because that is
                # when a machine is awake and idle. So what matters is what a person loses when the
                # runner restarts under them.
                step("what survives a restart")
                # A prompt that cannot start yet: the fake refuses the turn, so it stays queued and
                # marked, which is what a team limit looks like and what a person would have typed.
                local(proxy_port, "POST", "/test/refuse-starts",
                      {"code": "limit_reached", "message": "Out of hours for the test.", "limit": "monthly_hours"})
                chat = rpc(url, session(), {"kind": "new_chat", "controls": {
                    "agent": "claude", "model": "sonnet", "effort": "low", "permission_mode": "bypassPermissions",
                    "interaction_mode": "build", "fast_mode": False, "output_style": "default", "codex_context_window": 0}})["chat"]
                command_id = secrets.token_hex(8)
                queued = rpc(url, session(), {"kind": "send", "chat_id": chat["id"], "text": "Wait for me"}, command_id=command_id)
                prompt_id = queued["prompt_id"]
                wait_for("the prompt is queued and marked", lambda: [p for p in
                         rpc(url, session(), {"kind": "transcript", "chat_id": chat["id"], "after_seq": -1})["transcript"]["queue"]["prompts"]
                         if p["id"] == prompt_id], 60, interval=3)

                # A terminal, opened the way a run script opens one, so its shell is a tmux session
                # the runner started rather than a socket the test holds.
                run_on(name, "mkdir -p ~/workspace/.bloom", timeout=60)
                run_on(name, "cat > ~/workspace/.bloom/settings.toml",
                       stdin='[scripts.run.probe]\nname = "Probe"\n'
                             'command = "echo probe-shell-$$ > ~/probe-shell.txt; sleep 600"\n',
                       timeout=120)
                # The runner's tmux is on a named socket, `-L bloom-<fingerprint of the database
                # path>`, not a socket file of its own; asking for the wrong one is how the first
                # attempt at this probe proved nothing.
                tmux = ("tmux -L $(ls ${TMUX_TMPDIR:-/tmp}/tmux-$(id -u) | grep '^bloom-' | head -1)")
                # A shell that takes its time starting, which is what a cold machine looks like and
                # what a keystroke sent too early falls into.
                run_on(name, "printf 'sleep 3\\n' >> ~/.bashrc", timeout=60)
                terminal = rpc(url, session(), {"kind": "run_script", "id": "probe"})["terminal"]["name"]
                # The shell itself, by its pid, rather than by anything it printed: a release without
                # the run-script fix never runs the command, and what is measured here is whether the
                # shell survives the restart.
                # `|| true` on both: after a restart the socket may be gone, and "gone" is an
                # answer worth printing rather than an exception to raise.
                panes = (f"{{ {tmux} list-panes -a -F '#{{session_name}} #{{pane_pid}}' 2>&1 || true; }}; "
                         "echo '--- tmux processes:'; pgrep -a tmux | head -3 || true; "
                         "echo '--- sockets:'; ls ${TMUX_TMPDIR:-/tmp}/tmux-$(id -u) 2>&1 || true")
                shell_before = wait_for("the terminal's shell exists",
                                        lambda: (run_on(name, panes, timeout=60).strip() or None), 120, interval=5)
                step(f"restarting the service under it, as an update does ({terminal}; {shell_before.splitlines()})")
                run_on(name, "sprite-env services restart bloom", timeout=120)
                wait_for("health answers again", lambda: https(url, path="/_bloom/health")[0] == 200, 180, interval=3)

                after = rpc(url, session(), {"kind": "transcript", "chat_id": chat["id"], "after_seq": -1})["transcript"]
                kept = [p for p in after["queue"]["prompts"] if p["id"] == prompt_id]
                step(f"the queue kept the prompt: {bool(kept)} ({[p.get('state') for p in kept]})")
                retried = rpc(url, session(), {"kind": "send", "chat_id": chat["id"], "text": "Wait for me"}, command_id=command_id)
                step(f"the same command id answers {retried.get('prompt_id') == prompt_id and 'the same prompt' or retried}")
                shell_after = run_on(name, panes, timeout=60).strip()
                before_pane = [line for line in shell_before.splitlines() if "script-" in line]
                after_pane = [line for line in shell_after.splitlines() if "script-" in line]
                step(f"the terminal's shell survived: {bool(after_pane) and before_pane == after_pane}")
                step("before: " + " | ".join(shell_before.splitlines()))
                step("after: " + " | ".join(shell_after.splitlines()))
                local(proxy_port, "POST", "/test/refuse-starts", None)

            if arguments.outage:
                # What a machine that cannot reach runbloom.app actually does, measured rather than
                # reasoned about: the reports are refused with 503, which is retryable, so they are
                # kept rather than dropped, and the process is watched while they pile up.
                step(f"staging a runbloom.app outage of {arguments.outage:g} minutes")
                pid = run_on(name, "pgrep -f 'bloom-runner(-exec)? serve' | head -1", timeout=60).strip()
                resident = lambda: int(run_on(name, f"awk '/VmRSS/ {{print $2}}' /proc/{pid}/status", timeout=60).split()[0])  # noqa: E731
                before_rss = resident()
                before_delivered = len([r for r in requests() if r["path"].endswith(("/summary", "/usage"))])
                local(proxy_port, "POST", "/test/refuse-reports", {"refuse": True})
                started = time.time()
                samples = []
                while time.time() - started < arguments.outage * 60:
                    # Something a person would be doing, so the machine stays awake and the reports
                    # it owes are the reports of a workspace in use rather than an idle one.
                    rpc(url, session(), {"kind": "rename_workspace", "name": f"Outage {int(time.time() - started)}s"})
                    samples.append((round(time.time() - started), resident()))
                    step(f"  {samples[-1][0]:>4}s  rss {samples[-1][1]} kB  "
                         f"refused {json.loads(local(proxy_port, 'POST', '/test/refuse-reports', {'refuse': True})[1])['refused']}")
                    time.sleep(120)
                refused = json.loads(local(proxy_port, "POST", "/test/refuse-reports", {"refuse": True})[1])["refused"]
                after_rss = resident()
                step(f"outage over: rss {before_rss} kB to {after_rss} kB ({after_rss - before_rss:+d} kB), "
                     f"{refused} reports refused")

                # What the machine said about it, to anybody at all.
                said = run_on(name, r"grep -icE 'runbloom|unreachable|report' /.sprite/logs/services/bloom.log || true", timeout=60)
                step(f"lines in the service log mentioning runbloom, unreachable or report: {said.strip()}")
                state = rpc(url, session(), {"kind": "workspace"})["workspace"]["workspace"]
                step(f"what a client reading the workspace can see about it: {json.dumps({k: v for k, v in state.items() if 'report' in k or 'control' in k or 'reach' in k})}")

                step("runbloom.app comes back")
                local(proxy_port, "POST", "/test/refuse-reports", {"refuse": False})
                delivered = wait_for("the backlog drains", lambda: (lambda n: n if n > before_delivered else None)(
                    len([r for r in requests() if r["path"].endswith(("/summary", "/usage"))])), 180, interval=5)
                time.sleep(20)
                arrived = [r for r in requests() if r["path"].endswith(("/summary", "/usage"))][before_delivered:]
                usage = [r["body"] for r in arrived if r["path"].endswith("/usage")]
                step(f"after the outage: {len(arrived)} reports arrived, {len(usage)} of them usage, "
                     f"sequences {[u.get('sequence') for u in usage]}")
                step(f"summaries arrived: {len(arrived) - len(usage)} (replace-latest, so one is the whole owed state)")

                # And what a restart does to whatever is still owed.
                run_on(name, "sprite-env services restart bloom", timeout=120)
                wait_for("health answers again", lambda: https(url, path="/_bloom/health")[0] == 200, 180, interval=3)
                step("restarted; whatever was still in memory is gone with the process")

            if arguments.update:
                # Releases are laid out under /opt/bloom beforehand, so the bootstrap takes them as
                # already downloaded: what this measures is the restart, the new process saying it
                # came up, and the rollback, which nothing else reaches.
                digest = hashlib.sha256(data).hexdigest() if package else "0" * 64
                installed = run_on(name, "readlink /opt/bloom/current").strip().rsplit("/", 1)[-1]
                updated = f"{version}-update"
                run_on(name, f"sudo cp -a /opt/bloom/{installed} /opt/bloom/{updated}")
                step(f"asking for an update to {updated}")
                status, _, body = https(url, "POST", "/_bloom/v1/control/update", token=issuer.token("control", "control", ["admin"]),
                                        body={"version": updated, "sha256": digest, "tag": f"runner-v{updated}"})
                assert status == 202, (status, body)
                wait_for(f"health answers with {updated}", lambda: json.loads(https(url, path="/_bloom/health")[2])["version"] == updated,
                         180, interval=3)
                step(f"updated: health answers with {updated}, current is {run_on(name, 'readlink /opt/bloom/current').strip()}")

                # The failure worth staging is the real one: the wrapper is intact and the binary
                # behind it will not start, which is what a bad release looks like from outside.
                broken = f"{version}-broken"
                run_on(name, f"sudo cp -a /opt/bloom/{updated} /opt/bloom/{broken} && "
                             f"printf '#!/bin/sh\\nexit 1\\n' | sudo tee /opt/bloom/{broken}/bin/bloom-runner-exec >/dev/null && "
                             f"sudo chmod +x /opt/bloom/{broken}/bin/bloom-runner-exec")
                step(f"asking for an update to {broken}, whose binary exits at once")
                asked_at = time.time()
                status, _, body = https(url, "POST", "/_bloom/v1/control/update", token=issuer.token("control", "control", ["admin"]),
                                        body={"version": broken, "sha256": digest, "tag": f"v{broken}"})
                assert status == 202, (status, body)
                try:
                    wait_for(f"the machine is back on {updated} and answering",
                             lambda: json.loads(https(url, path="/_bloom/health")[2])["version"] == updated
                             and run_on(name, "readlink /opt/bloom/current").strip().endswith(updated), 420, interval=5)
                except RuntimeError:
                    print(run_on(name, "readlink /opt/bloom/current; cat /var/tmp/bloom-update.log 2>/dev/null; "
                                       "cat /var/tmp/bloom-update-pending 2>/dev/null; sprite-env services list; "
                                       "tail -n 30 /.sprite/logs/services/bloom.log 2>/dev/null", timeout=60)[-6000:],
                          file=sys.stderr)
                    raise
                healed_in = time.time() - asked_at
                # What the machine itself says about the failure: how many times the supervisor
                # brought the dead release back, and what the wrapper wrote on its way past.
                # The service's own log is a file; there is no `services logs` subcommand, which is
                # what made this look silent the first time it was asked for.
                evidence = run_on(name, "sprite-env services list; echo ---; "
                                        "grep -h 'going back to' /.sprite/logs/services/bloom.log /var/tmp/bloom-update.log "
                                        "2>/dev/null | tail -n 2; echo ---; "
                                        "ls /var/tmp/bloom-update-pending 2>/dev/null || echo 'marker gone'", timeout=60)
                step(f"healed in {healed_in:.0f} s, back on {updated}")
                step("what the machine says: " + " ".join(evidence.split())[:400])

            if grant:
                step("live turn")
                controls = {"agent": "claude", "model": "sonnet", "effort": "low", "permission_mode": "bypassPermissions",
                            "interaction_mode": "build", "fast_mode": False, "output_style": "default", "codex_context_window": 0}
                chat = rpc(url, session(), {"kind": "new_chat", "controls": controls})["chat"]
                rpc(url, session(), {"kind": "send", "chat_id": chat["id"],
                                     "text": "Reply with exactly the single word pineapple, and nothing else."})
                try:
                    answer = wait_for("the agent answers", lambda: reader.find(
                        lambda e: e["kind"] == "message" and e["message"]["kind"] == "assistantText"
                        and "pineapple" in json.dumps(e["message"]["payload"]).lower()), 300, interval=3)
                except RuntimeError:
                    # What the chat and its queue say, and whether the CLI is there, with the credential
                    # taken out of anything printed in case an error echoed its environment.
                    secret_values = [value for value in grant.get("environment", {}).values()] + [grant.get("key", "")]
                    def redacted(text):
                        for value in secret_values:
                            if value:
                                text = text.replace(value, "[redacted]")
                        return text
                    transcript = rpc(url, session(), {"kind": "transcript", "chat_id": chat["id"], "after_seq": -1})
                    rows = [row for row in transcript["transcript"]["messages"] if row["kind"] not in ("system", "user")]
                    print(redacted(json.dumps({"chat": transcript["transcript"]["chat"]["state"], "queue": transcript["transcript"].get("queue"),
                                               "rows": rows})[:8000]), file=sys.stderr)
                    # Whether the credential reached the agent unchanged, as a yes or no: the hash of the
                    # value in the running process's environment against the hash of the one sent.
                    for key, value in grant.get("environment", {}).items():
                        expected = hashlib.sha256(value.encode()).hexdigest()
                        found = run_on(name, "for p in $(pgrep -u sprite -f 'claude.*stream-json'); do "
                                             f"tr '\\0' '\\n' < /proc/$p/environ | grep '^{key}=' | cut -d= -f2- | tr -d '\\n' | sha256sum | cut -d' ' -f1; done",
                                       timeout=60).split()
                        print(f"{key} in the agent's environment matches what was sent: {expected in found} ({len(found)} processes)", file=sys.stderr)
                    print(redacted(run_on(name, "command -v claude; ls -la ~/.local/bin 2>/dev/null | head; "
                                                "tail -n 60 /.sprite/logs/services/bloom.log 2>/dev/null", timeout=60))[-6000:], file=sys.stderr)
                    raise
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
                    print(run_on(name, "tail -n 80 /.sprite/logs/services/bloom.log 2>/dev/null", timeout=60)[-6000:], file=sys.stderr)
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

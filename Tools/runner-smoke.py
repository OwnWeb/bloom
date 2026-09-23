#!/usr/bin/env python3
"""Boot a real bloom-runner against a fake runbloom.app and check what a machine must do first.

    python3 Tools/runner-smoke.py <path to bloom-runner>

Standard library and `openssl` only, so it runs on a bare Ubuntu with the packaged server and no
Swift, which is the point: it proves the package, not the build directory.

It checks that the server posts its first summary before anything else, answers health without a
token, refuses a command without one and with a forged one, answers a command and opens an event
stream with a token runbloom.app would have signed, refuses a control call made with a session
token, and on SIGTERM posts a final summary saying it is not awake and a usage report ending in
`released` exactly once per hold. Setup is expected to fail here (there is no GitHub token to clone with) and is not
what this checks.
"""

import http.client
import json
import os
import pathlib
import signal
import socket
import shutil
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from bloom_fake_runbloom import FakeRunbloom, Issuer  # noqa: E402

WORKSPACE = "01k5a7d3v1x0m8n2q4r6s9t0wy"
MACHINE = "01k5a7e4w2y1n9m3r5s7t0v1xz"
USER = "01k5a7c2b0z9y8x7w6v5t4s3rq"
SECRET = "smoke-secret-" + "x" * 51
REGISTRATION_TOKEN = "r" * 64

# The smoke's default repository does not exist, on purpose: the checks below are about the wire
# and the sandbox, and nothing here should need github.com to answer. A rig that wants setup's
# real clone names a repository that does exist, and then the clone, a commit and a push are
# checked as well. `Tools/sprite-smoke.sh --from-source` is the one that does.
REPOSITORY = os.environ.get("BLOOM_SMOKE_REPOSITORY") or "spatie/bloom-smoke"
BRANCH = os.environ.get("BLOOM_SMOKE_BRANCH") or ("master" if os.environ.get("BLOOM_SMOKE_REPOSITORY") else "smoke")
CLONES = bool(os.environ.get("BLOOM_SMOKE_REPOSITORY"))
# The branch the workspace works on, which is what a push writes to. It is deliberately not the
# base branch: a rig that pushes must not be one keystroke away from writing to main.
BASE_BRANCH = os.environ.get("BLOOM_SMOKE_BASE_BRANCH") or BRANCH
PUSHES = os.environ.get("BLOOM_SMOKE_PUSH") == "1"


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




def report_setup(scratch, lines=12):
    """What setup wrote, step by step.

    Setup does not log to stderr: `SetupLog` puts a file per step under the data directory, so a
    run that failed said only that a directory was missing, and the sentence naming the reason sat
    in a file nobody opened. Printing it is the difference between "the clone failed" and
    "fatal: could not create work tree dir: Permission denied".
    """
    directory = scratch / "data" / "setup"
    print("----- what setup itself recorded -----")
    if not directory.is_dir():
        print("  setup wrote nothing at", directory)
        return
    for entry in sorted(directory.iterdir()):
        body = entry.read_text(errors="replace").splitlines()
        print(f"  [{entry.name}] {len(body)} lines")
        for line in body[-lines:]:
            print("   ", line[:200])


def check_the_clone(server_binary, environment, scratch, worktree, log):
    """Setup's own clone, then a commit and a push through the hardened git.

    Every Runner fault of 21 September 2026 was in this sequence and none of them was in a part of
    it the smoke ran: the worktree was not created, then it was not group writable, then setup
    deleted what provisioning had made, then an empty `http.sslCert` made curl try to open a file
    called nothing and every clone died with "error reading X.509 key file". Each was found on a
    machine, seventeen minutes and one release apart, because nothing here cloned anything.

    What this proves and what it does not. The clone is real and so is the commit. The push has no
    credentials to offer and is expected to be refused; what is checked is *which* refusal, because
    a certificate failure is a broken transport and an authorisation failure is a working one.
    A push that lands is not proven here and would need a repository to write to.
    """
    # **A `.git` directory is not a clone.** Waiting for one to appear passed while every clone was
    # failing: git makes it in the first second, and on failure what is left behind is an empty
    # repository with no commits in it. The smoke said CLONE OK, the commit that followed said
    # "root-commit", and nobody read the word. So what is waited for is a commit reachable from
    # HEAD, read with the real git rather than through the shim because this is the measuring
    # instrument and not the thing being measured.
    real_git = shutil.which("git", path="/usr/bin:/bin:/usr/local/bin") or "/usr/bin/git"

    def cloned():
        # Refs land before the checkout finishes, so a count on its own is a clone still in
        # progress: staging a file against it fails on `.git/index.lock` held by setup's own git.
        if (worktree / ".git" / "index.lock").exists():
            return False
        head = subprocess.run(
            [real_git, "-c", "safe.directory=" + str(worktree), "-C", str(worktree),
             "rev-list", "--count", "HEAD"],
            capture_output=True, text=True)
        return head.returncode == 0 and head.stdout.strip().isdigit() and int(head.stdout.strip()) > 0

    try:
        wait_for("the clone brings a commit into the worktree", cloned, timeout=180)
    except SystemExit:
        log.flush()
        print("CLONE FAILED: no checkout at", worktree)
        # Setup writes a file per step under the data directory rather than to stderr, so without
        # this the only thing a failed clone says is that a directory is missing.
        setup_directory = scratch / "data" / "setup"
        report_setup(scratch)
        print("----- server.log tail -----")
        print("\n".join((scratch / "server.log").read_text().splitlines()[-12:]))
        raise
    revisions = subprocess.run(
        [real_git, "-c", "safe.directory=" + str(worktree), "-C", str(worktree),
         "rev-list", "--count", "HEAD"], capture_output=True, text=True).stdout.strip()
    print(f"CLONE OK: setup cloned {REPOSITORY} into {worktree}, {revisions} commits")

    # The shim is `bloom-runner git-v2`, and it takes the real tools from the environment the
    # sandbox hands it rather than from PATH, which is the point of it.
    exec_path = subprocess.run([real_git, "--exec-path"], capture_output=True, text=True).stdout.strip()
    shim = dict(environment,
                GIT_TERMINAL_PROMPT="0", BLOOM_REPOSITORY=REPOSITORY,
                BLOOM_REAL_GIT=real_git, BLOOM_REAL_GIT_REMOTE_HTTPS=exec_path + "/git-remote-https",
                GIT_AUTHOR_NAME="Smoke", GIT_COMMITTER_NAME="Smoke",
                GIT_AUTHOR_EMAIL="smoke@example.invalid", GIT_COMMITTER_EMAIL="smoke@example.invalid")

    def shimmed(*arguments):
        return subprocess.run([str(server_binary), "git-v2", *arguments],
                              cwd=worktree, env=shim, capture_output=True, text=True, timeout=120)

    (worktree / "smoke.txt").write_text(f"written by the smoke at {time.time()}\n")
    add = shimmed("add", "smoke.txt")
    assert add.returncode == 0, ("staging a file must work", (add.stdout + add.stderr)[:400])
    commit = shimmed("commit", "-m", "A commit made through the hardened git")
    assert commit.returncode == 0, ("committing reaches no network and must simply work",
                                    (commit.stdout + commit.stderr)[:400])
    print("COMMIT OK:", (commit.stdout or commit.stderr).strip().splitlines()[0][:120])

    push = shimmed("push", "--dry-run", "origin", "HEAD:refs/heads/smoke")
    said = (push.stderr + push.stdout).strip()
    transport = [phrase for phrase in ("PEM client certificate", "X.509", "SSL certificate problem",
                                       "sslCert", "unable to set private key", "GnuTLS", "schannel")
                 if phrase in said]
    if transport:
        git_directory = worktree / ".git"
        print("OWNERS: worktree uid=%d, .git uid=%d, running as uid=%d" % (
            worktree.stat().st_uid, git_directory.stat().st_uid, os.getuid()))
        raise SystemExit(f"push failed in the transport rather than the authorisation: {transport}\n{said}")
    print("PROBE PUSH (outside the sandbox, so a refusal here is correct):",
          push.returncode, said.replace("\n", " | ")[:160])
    report_setup(scratch, lines=6)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    server_binary = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="bloom-runner-smoke-") as scratch:
        scratch = pathlib.Path(scratch)
        # mkdtemp is 0700 and a machine's home is 0751, so without this the sandbox user cannot
        # even reach the worktree and the clone fails for a reason production does not have.
        os.chmod(scratch, 0o755)
        # A real machine's worktree is /home/sprite/workspace, prepared by provision-sandbox.sh:
        # owned by the shared group, setgid, and named in git's system-wide safe.directory. A temp
        # directory is none of those, so a rig that wants setup's real clone points this at the one
        # it provisioned.
        worktree = pathlib.Path(os.environ.get("BLOOM_SMOKE_WORKTREE") or (scratch / "worktree"))
        port = free_port()
        fake_port = free_port()
        base = f"http://127.0.0.1:{fake_port}"
        issuer = Issuer(scratch / "issuer", base, WORKSPACE)
        fake = FakeRunbloom(
            SECRET, issuer.jwks, workspace=WORKSPACE, machine=MACHINE,
            registration_token=REGISTRATION_TOKEN, port=fake_port,
        )
        threading.Thread(target=fake.serve_forever, daemon=True).start()

        config = scratch / "workspace.json"
        config.write_text(json.dumps({
            "workspace_id": WORKSPACE, "issuer": base, "jwks_url": base + "/.well-known/jwks.json", "base_url": base,
            "workspace_secret": SECRET, "allowed_origins": ["https://runbloom.app"], "public_url": "https://smoke.example",
            "repository": REPOSITORY, "branch": BRANCH, "base_branch": BASE_BRANCH, "name": "Smoke", "team_id": "01k5a7b1a9y8x7w6v5t4s3r2qp",
            "machine_identity": {
                "version": 1, "machine_id": MACHINE, "registration_token": REGISTRATION_TOKEN,
                "registration_expires_at": time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 300)
                ),
            },
        }))
        config.chmod(0o600)
        environment = dict(os.environ, BLOOM_WORKSPACE_CONFIG=str(config), BLOOM_DATA_DIR=str(scratch / "data"),
                           BLOOM_WORKTREE=str(worktree), BLOOM_RUNNER_PORT=str(port),
                           BLOOM_PUBLIC_PORT=str(free_port()), BLOOM_UPDATE_MARKER=str(scratch / "update-pending"),
                           HOME=str(scratch / "home"))
        (scratch / "home").mkdir()
        log = open(scratch / "server.log", "w")
        process = subprocess.Popen([str(server_binary), "serve"], env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for("the first summary arrives", lambda: fake.recorded("/summary"))
            if CLONES:
                # **Wait for setup to finish before touching the worktree.** Staging a file while
                # setup was still working took `.git/index.lock` out from under setup's own git,
                # which then reported "Another git process seems to be running in this repository"
                # and failed a run that was otherwise fine. Nothing shares a worktree with setup on
                # a real machine, so a rig that does is testing something production never does.
                def settled():
                    reports = fake.recorded("/summary")
                    states = [r.get("setup", {}).get("state") for r in reports]
                    return any(state in ("succeeded", "failed", "skipped", "ignored") for state in states)

                wait_for("setup reaches a settled state", settled, timeout=300)
                states = [r.get("setup", {}).get("state") for r in fake.recorded("/summary")]
                print("SETUP:", " -> ".join(dict.fromkeys(state for state in states if state)))
                report_setup(scratch, lines=10)
                database = scratch / "data" / "bloom.sqlite"
                if database.exists():
                    import sqlite3
                    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
                    columns = [row[1] for row in connection.execute("PRAGMA table_info(workspaces)")]
                    for column in ("setup_log", "setupLog", "setup_output"):
                        if column in columns:
                            for (text,) in connection.execute(f"SELECT {column} FROM workspaces"):
                                print(f"----- the run's log, as the workspace row holds it ({column}) -----")
                                print((text or "")[-2500:])
                            break
                    connection.close()
                if any(state == "failed" for state in states):
                    log.flush()
                    print("----- server.log, because setup failed -----")
                    print("\n".join((scratch / "server.log").read_text().splitlines()[-40:]))
                check_the_clone(server_binary, environment, scratch, worktree, log)

            first = fake.recorded("/summary")[0]
            assert first["title"] == "Smoke" and first["branch"] == BRANCH, first

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

            if CLONES:
                # The setup output the UI shows, asked for the way the UI asks. A note written
                # after its step has closed lives only in the run's log, so this is the only place
                # the sentence explaining a failure can be read.
                looking = {"protocol": "bloom-workspace", "version": 1, "command_id": "smoke-setup",
                           "operation": {"kind": "setupOutput"}}
                status, body = request(port, "POST", "/_bloom/v1/rpc", token=session, body=looking)
                print("----- setup output, as the UI shows it -----")
                print(json.dumps(json.loads(body).get("result", {}), indent=2)[:2500])

            if PUSHES:
                # The real thing: the push RPC registers a turn, takes a credential grant, launches
                # a person-bound sandbox and runs git push inside it. Nothing about this is a
                # stand-in, which is the point. Everything a Cloud workspace does to publish work
                # goes through here.
                pushing = {"protocol": "bloom-workspace", "version": 1, "command_id": "smoke-push",
                           "operation": {"kind": "push"}}
                status, body = request(port, "POST", "/_bloom/v1/rpc", token=session, body=pushing)
                reply = json.loads(body)
                assert status == 200 and reply.get("result", {}).get("kind") == "accepted", (status, body)
                print(f"PUSH OK: {BRANCH} pushed to {REPOSITORY} through a person-bound sandbox")

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
            status = process.wait(timeout=60)
            # A server that reports everything and then dies on its way out is not a server that
            # shut down, and a machine update rolls back on exactly this.
            assert status == 0, f"bloom-runner exited with status {status} on SIGTERM"
            summaries = fake.recorded("/summary")
            assert summaries[-1]["awake"] is False, summaries[-1]
            # Stopping is not losing a capability. The last summary once left out the model
            # gateway's, because the gateway stops first, and runbloom.app revoked the machine's
            # model grants on reading it.
            served = set(summaries[0].get("bloom_runner_capabilities", []))
            kept = set(summaries[-1].get("bloom_runner_capabilities", []))
            assert served <= kept, (summaries[0], summaries[-1])
            usage = fake.recorded("/usage")
            events = [event for report in usage for event in report["events"]]
            # Every hold ends in exactly one `released`, the last word about being awake, because
            # runbloom.app adds its margin once per `released`. A fresh machine can fail closed
            # during setup before it ever acquires a hold, which leaves this list empty.
            holds = [event["kind"] for event in events if event["kind"] in ("awake", "released")]
            assert holds.count("awake") == holds.count("released"), usage
            assert not holds or holds[-1] == "released", usage
        except BaseException:
            log.flush()
            print((scratch / "server.log").read_text()[-16000:], file=sys.stderr)
            raise
        finally:
            if process.poll() is None:
                process.kill()
            fake.shutdown()
    print("bloom-runner smoke test passed")


def _answers(port):
    try:
        return request(port, "GET", "/_bloom/health")[0] == 200
    except OSError:
        return False


if __name__ == "__main__":
    main()

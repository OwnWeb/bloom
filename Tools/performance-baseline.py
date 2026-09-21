#!/usr/bin/env python3
"""Measure local startup and streaming references without using credentials or network access.

Run from the repository root:

    python3 Tools/performance-baseline.py --output baseline.json

The output is JSON so two revisions can be compared without scraping prose. This is deliberately
not a pass or fail test. Timing budgets belong in the accompanying document and are evaluated over
several samples, never as wall-clock assertions in the correctness suite.
"""

import argparse
import json
import math
import os
import pathlib
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = pathlib.Path(__file__).resolve().parent.parent


def run(command, *, cwd=ROOT, environment=None, stdin=None, check=True):
    return subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=check,
    )


def version(command):
    executable = shutil.which(command[0])
    if executable is None:
        return None
    result = run([executable, *command[1:]], check=False)
    text = result.stdout.strip() or result.stderr.strip()
    return text.splitlines()[0] if text else None


def machine_context():
    commit = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain", "--untracked-files=no"]).stdout.strip())
    context = {
        "captured_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "commit": commit,
        "tracked_files_dirty": dirty,
        "platform": platform.platform(),
        "architecture": platform.machine(),
        "logical_cpus": os.cpu_count(),
        "python": platform.python_version(),
        "tools": {
            "git": version(["git", "--version"]),
            "gh": version(["gh", "--version"]),
            "tmux": version(["tmux", "-V"]),
            "composer": version(["composer", "--version"]),
            "npm": version(["npm", "--version"]),
            "swift": version(["swift", "--version"]),
        },
    }
    if sys.platform == "darwin":
        context["machine"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], check=False).stdout.strip()
        memory = run(["sysctl", "-n", "hw.memsize"], check=False).stdout.strip()
        context["memory_bytes"] = int(memory) if memory.isdigit() else None
    return context


def percentile(values, percentage):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * percentage) - 1)]


def summary(milliseconds):
    return {
        "samples": len(milliseconds),
        "minimum_ms": round(min(milliseconds), 3),
        "median_ms": round(statistics.median(milliseconds), 3),
        "p95_ms": round(percentile(milliseconds, 0.95), 3),
        "maximum_ms": round(max(milliseconds), 3),
    }


def measure(command, *, runs, warmups=0, cwd=ROOT, environment=None, stdin=None, verify=None):
    values = []
    for index in range(warmups + runs):
        began = time.perf_counter_ns()
        result = run(command, cwd=cwd, environment=environment, stdin=stdin)
        elapsed = (time.perf_counter_ns() - began) / 1_000_000
        if verify is not None:
            verify(result)
        if index >= warmups:
            values.append(elapsed)
    return summary(values)


def credential_resolution(runs, warmups):
    with tempfile.TemporaryDirectory(prefix="bloom-credential-baseline-") as directory:
        root = pathlib.Path(directory)
        helper = root / "credential-helper"
        helper.write_text("#!/bin/sh\nprintf 'username=benchmark\\npassword=benchmark\\n'\n")
        helper.chmod(0o700)
        config = root / "gitconfig"
        run(["git", "config", "--file", str(config), "credential.helper", f"!\"{helper}\""])
        environment = {
            "HOME": directory,
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GIT_CONFIG_GLOBAL": str(config),
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
        }
        request = "protocol=https\nhost=benchmark.invalid\n\n"

        def verify(result):
            fields = set(result.stdout.splitlines())
            if "username=benchmark" not in fields or "password=benchmark" not in fields:
                raise RuntimeError("the isolated credential helper did not answer")

        return measure(
            ["git", "credential", "fill"], runs=runs, warmups=warmups,
            environment=environment, stdin=request, verify=verify,
        )


def wait_for_file(marker, deadline):
    while time.perf_counter() < deadline:
        if marker.exists():
            return
        time.sleep(0.001)
    raise RuntimeError(f"timed out waiting for the isolated terminal marker {marker.name}")


def tmux_terminal_startup(runs, warmups):
    tmux = shutil.which("tmux")
    if tmux is None:
        return None
    socket = "bloom-baseline-" + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="bloom-terminal-baseline-") as directory:
        root = pathlib.Path(directory)
        environment = dict(os.environ)
        environment["HOME"] = directory
        environment["LC_ALL"] = "C"

        def start(name, marker):
            began = time.perf_counter_ns()
            run([
                tmux, "-L", socket, "new-session", "-d", "-s", name,
                f"printf ready > {marker}; exec sleep 30",
            ], environment=environment)
            wait_for_file(marker, time.perf_counter() + 5)
            elapsed = (time.perf_counter_ns() - began) / 1_000_000
            return elapsed

        cold = []
        for index in range(warmups + runs):
            marker = root / f"cold-{index}"
            elapsed = start(f"cold-{index}", marker)
            run([tmux, "-L", socket, "kill-server"], environment=environment, check=False)
            if index >= warmups:
                cold.append(elapsed)

        bootstrap = root / "bootstrap"
        start("bootstrap", bootstrap)
        warm = []
        for index in range(warmups + runs):
            marker = root / f"warm-{index}"
            elapsed = start(f"warm-{index}", marker)
            run([tmux, "-L", socket, "kill-session", "-t", f"warm-{index}"], environment=environment)
            if index >= warmups:
                warm.append(elapsed)
        run([tmux, "-L", socket, "kill-server"], environment=environment, check=False)
    return {"cold": summary(cold), "warm": summary(warm)}


def stream_child(seconds, events_per_second, payload_bytes):
    payload = "x" * payload_bytes
    interval = 1 / events_per_second
    deadline = time.perf_counter() + seconds
    next_event = time.perf_counter()
    events = 0
    while time.perf_counter() < deadline:
        encoded = json.dumps({"type": "model_delta", "sequence": events, "text": payload})
        decoded = json.loads(encoded)
        if decoded["sequence"] != events:
            return 1
        events += 1
        next_event += interval
        remaining = next_event - time.perf_counter()
        if remaining > 0:
            time.sleep(remaining)
    return 0


def peak_rss_bytes(pid):
    result = run(["ps", "-o", "rss=", "-p", str(pid)], check=False)
    value = result.stdout.strip()
    return int(value) * 1024 if value.isdigit() else 0


def long_stream(seconds, events_per_second, payload_bytes):
    command = [
        sys.executable, str(pathlib.Path(__file__).resolve()), "--stream-child",
        "--stream-seconds", str(seconds), "--events-per-second", str(events_per_second),
        "--payload-bytes", str(payload_bytes),
    ]
    began_wall = time.perf_counter()
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    peak = 0
    usage = None
    status = 0
    while True:
        waited, status, usage = os.wait4(process.pid, os.WNOHANG)
        if waited == process.pid:
            process.returncode = os.waitstatus_to_exitcode(status)
            break
        peak = max(peak, peak_rss_bytes(process.pid))
        time.sleep(0.1)
    stderr = process.stderr.read()
    if process.returncode != 0:
        raise RuntimeError(f"stream worker exited {process.returncode}: {stderr[-300:]}")
    elapsed = time.perf_counter() - began_wall
    return {
        "elapsed_seconds": round(elapsed, 3),
        "events_per_second": events_per_second,
        "payload_bytes": payload_bytes,
        "payload_mebibytes": round(seconds * events_per_second * payload_bytes / 1_048_576, 3),
        "peak_rss_bytes": peak,
        "worker_cpu_seconds": round(usage.ru_utime + usage.ru_stime, 3),
        "note": "Synthetic JSON encode/decode stream. Peak RSS is sampled every 100 ms.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=15)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--stream-seconds", type=float, default=10)
    parser.add_argument("--events-per-second", type=int, default=50)
    parser.add_argument("--payload-bytes", type=int, default=4096)
    parser.add_argument("--stream-child", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.stream_child:
        return stream_child(arguments.stream_seconds, arguments.events_per_second, arguments.payload_bytes)
    if arguments.runs < 1 or arguments.warmups < 0:
        parser.error("runs must be positive and warmups cannot be negative")

    git = shutil.which("git") or "git"
    gh = shutil.which("gh")
    results = {
        "schema": 1,
        "definitions": {
            "command": "wall time from process spawn until successful exit",
            "credential_resolution": "git credential fill through an isolated local helper",
            "terminal_cold": "isolated tmux server start until its shell writes a marker",
            "terminal_warm": "new session on an isolated running tmux server until its shell writes a marker",
        },
        "context": machine_context(),
        "configuration": {
            "runs": arguments.runs,
            "warmups": arguments.warmups,
        },
        "measurements": {
            "shell_noop": measure(["/bin/zsh", "-dfc", ":"], runs=arguments.runs, warmups=arguments.warmups),
            "git_version": measure([git, "--version"], runs=arguments.runs, warmups=arguments.warmups),
            "git_status": measure(
                [git, "--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=no"],
                runs=arguments.runs, warmups=arguments.warmups,
            ),
            "git_credential_fill": credential_resolution(arguments.runs, arguments.warmups),
            "terminal_startup": tmux_terminal_startup(arguments.runs, arguments.warmups),
            "synthetic_long_stream": long_stream(
                arguments.stream_seconds, arguments.events_per_second, arguments.payload_bytes,
            ),
        },
    }
    if gh is not None:
        results["measurements"]["gh_version"] = measure(
            [gh, "--version"], runs=arguments.runs, warmups=arguments.warmups,
        )
    encoded = json.dumps(results, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded)
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

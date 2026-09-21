#!/usr/bin/env python3
"""Long-running service substitute used to inspect launch isolation and ordering."""

import hashlib
import http.server
import json
import os
import pathlib
import signal
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
STATE = ROOT / ".bloom-canary/services"
SCOPED_NAMES = {
    "CANARY_SETUP_SECRET", "CANARY_APP_SECRET", "CANARY_QUEUE_SECRET",
    "CANARY_REALTIME_SECRET", "CANARY_ASSETS_SECRET",
}
PROVIDER_NAMES = {
    "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY",
    "CODEX_API_KEY", "XAI_API_KEY", "GROK_API_KEY",
}
running = True


def stop(*_):
    global running
    running = False


def record(service, expected):
    value = os.environ.get(expected)
    result = {
        "service": service,
        "ordinary": os.environ.get("CANARY_ORDINARY") == "ordinary-visible",
        "present_scopes": sorted(name for name in SCOPED_NAMES if os.environ.get(name)),
        "scope_digest": hashlib.sha256(value.encode()).hexdigest() if value else None,
        "provider_names": sorted(name for name in PROVIDER_NAMES if os.environ.get(name)),
        "started_at_ns": time.time_ns(),
        "pid": os.getpid(),
    }
    STATE.mkdir(parents=True, exist_ok=True)
    temporary = STATE / f"{service}.tmp"
    temporary.write_text(json.dumps(result, sort_keys=True) + "\n")
    temporary.replace(STATE / f"{service}.json")


class App(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        body = b"ok\n" if self.path == "/up" else (ROOT / "app/index.html").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain" if self.path == "/up" else "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: service.py SERVICE EXPECTED_SECRET_NAME")
    service, expected = sys.argv[1:]
    record(service, expected)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    if service == "app":
        server = http.server.ThreadingHTTPServer(("127.0.0.1", int(os.environ["BLOOM_APP_PORT"])), App)
        server.timeout = 0.25
        while running:
            server.handle_request()
        server.server_close()
        return
    while running:
        time.sleep(0.25)


if __name__ == "__main__":
    main()

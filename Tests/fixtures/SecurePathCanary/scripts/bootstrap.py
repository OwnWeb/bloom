#!/usr/bin/env python3
"""Build the deterministic canary fixture without reaching a package registry."""

import hashlib
import json
import os
import pathlib
import shutil
import sqlite3
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
STATE = ROOT / ".bloom-canary"
PROVIDER_NAMES = {
    "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY",
    "CODEX_API_KEY", "XAI_API_KEY", "GROK_API_KEY",
}
SCOPED_NAMES = {
    "CANARY_SETUP_SECRET", "CANARY_APP_SECRET", "CANARY_QUEUE_SECRET",
    "CANARY_REALTIME_SECRET", "CANARY_ASSETS_SECRET",
}


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest() if value else None


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    temporary.replace(path)


def capture(phase):
    present_scopes = sorted(name for name in SCOPED_NAMES if os.environ.get(name))
    provider_names = sorted(name for name in PROVIDER_NAMES if os.environ.get(name))
    return {
        "phase": phase,
        "ordinary": os.environ.get("CANARY_ORDINARY") == "ordinary-visible",
        "present_scopes": present_scopes,
        "scope_digest": digest(os.environ.get("CANARY_SETUP_SECRET")),
        "provider_names": provider_names,
        "at_ns": time.time_ns(),
    }


def setup():
    STATE.mkdir(exist_ok=True)
    database = STATE / "canary.sqlite"
    connection = sqlite3.connect(database)
    migration = (ROOT / "database/migrations/001_create_canary_state.sql").read_text()
    connection.executescript(migration)
    connection.execute(
        "INSERT OR REPLACE INTO canary_state(key, value, updated_at) VALUES (?, ?, datetime('now'))",
        ("persistent", "created-by-setup"),
    )
    connection.execute("INSERT INTO canary_jobs(payload) VALUES (?)", ("first-job",))
    connection.commit()
    connection.close()

    vendor = ROOT / "vendor/psr/log"
    vendor.mkdir(parents=True, exist_ok=True)
    (vendor / "CANARY_PACKAGE").write_text("psr/log 3.0.2\n")
    modules = ROOT / "node_modules/vite"
    modules.mkdir(parents=True, exist_ok=True)
    (modules / "CANARY_PACKAGE").write_text("vite 6.1.0\n")
    assets = ROOT / "public/assets"
    assets.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "resources/js/app.js", assets / "app.js")
    atomic_json(STATE / "setup.json", capture("setup"))


def resume():
    STATE.mkdir(exist_ok=True)
    state = capture("resume")
    database = STATE / "canary.sqlite"
    state["persistent"] = False
    if database.exists():
        connection = sqlite3.connect(database)
        found = connection.execute(
            "SELECT value FROM canary_state WHERE key = 'persistent'"
        ).fetchone()
        connection.close()
        state["persistent"] = found == ("created-by-setup",)
    atomic_json(STATE / "resume.json", state)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in {"setup", "resume"}:
        raise SystemExit("usage: bootstrap.py setup|resume")
    setup() if sys.argv[1] == "setup" else resume()

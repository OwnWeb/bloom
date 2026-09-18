#!/usr/bin/env python3
"""Reads what one machine says about an update it has already been through. Changes nothing.

    python3 Tools/read-update-evidence.py <sprite-name> [--org <organisation>]

**For the first real supervised update of a live workspace.** runbloom.app measures its own half
from `machines.update_health_reads`; this is the machine's half, and it is deliberately taken
*after* the event rather than during it. Polling a machine from outside wakes it (measured: a
paused Sprite answers `/_bloom/health` in 0.2 s, and answering is waking), so a watcher sitting on
health through the window would hold awake the very workspace whose idleness triggers the update.
The machine's own records outlive the window, so nothing is lost by waiting:

  * `/var/tmp/bloom-update.log` is appended by the start wrapper and survives the marker, any
    rotation and any number of updates. This is the durable account.
  * `/var/tmp/bloom-update-pending` is deleted by a runner that got as far as listening, so its
    absence means the update came up and its presence means it did not. When it is there, its three
    lines are the asked version, the version to go back to, and how many starts have seen it.
  * `/opt/bloom/current` names the release actually running, and the versions beside it are the
    ones a rollback can reach without a download.
  * The provider's own `restart_count` corroborates the wrapper's sentence: a release that was
    brought back twice before the wrapper gave up reads as three.
  * `/_bloom/health` is the version answering now, which is what `runner_version` should agree with.

Read-only by construction: every command here is a read, and none of them writes to the machine.
"""

import argparse
import json
import subprocess

SPRITE = "sprite"

READS = [
    ("the release running now", "readlink /opt/bloom/current"),
    ("releases on disk, which is what a rollback can reach", "ls -1 /opt/bloom"),
    # Absence is only evidence when there has been an update: a runner that got as far as
    # listening deletes it. On a machine with no Bloom on it at all, absence means nothing, which
    # is why this reports what it found rather than what it concludes.
    ("the update marker, whose three lines are the asked version, the one to go back to, and starts seen",
     "cat /var/tmp/bloom-update-pending 2>/dev/null || echo '(absent)'"),
    ("the wrapper's own account, newest last", "tail -n 20 /var/tmp/bloom-update.log 2>/dev/null || echo '(no update log)'"),
    ("the service, with the provider's restart count", "sprite-env services list"),
    ("what the server said around the restart",
     "grep -nE 'going back to|did not come up|Server started|stopping|stopped' /.sprite/logs/services/bloom.log | tail -n 12"),
    ("the version answering now", "curl -s --max-time 5 http://127.0.0.1:8080/_bloom/health || echo '(health did not answer)'"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("machine")
    parser.add_argument("--org", default=None, help="the provider organisation the machine belongs to")
    arguments = parser.parse_args()

    for title, command in READS:
        print(f"\n==> {title}")
        argv = [SPRITE, "exec"]
        if arguments.org:
            argv += ["-o", arguments.org]
        argv += ["-s", arguments.machine, "--no-port-forward", "--", "bash", "-lc", command]
        result = subprocess.run(argv, capture_output=True, text=True, timeout=180)
        text = (result.stdout or result.stderr).strip()
        print(text if text else "(nothing)")
        if title.startswith("the service") and result.stdout.strip().startswith("["):
            try:
                for service in json.loads(result.stdout):
                    state = service.get("state", {})
                    print(f"    {service['name']}: restart_count={state.get('restart_count')} status={state.get('status')}")
            except ValueError:
                pass


if __name__ == "__main__":
    main()

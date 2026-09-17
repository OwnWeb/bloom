#!/bin/sh
# What the `bloom` service actually runs, installed as bin/bloom-runner with the real binary beside
# it as bin/bloom-runner-exec. It decides one thing and then gets out of the way.
#
# **A release that cannot start has to be undone by something the restart re-runs.** The bootstrap
# script cannot: `sprite-env services restart bloom` ends the script that called it, so the loop
# that was meant to watch the health check and flip the symlink back is killed by the very restart
# it asked for. Measured on a Sprite: a service whose process exits at once is restarted for ever,
# about once a minute (restart_count 1, 2, 8, 12 over seven minutes, `next_restart_at` always set).
# So the decision moves to the start, where the supervisor keeps handing it another chance.
#
# `/var/tmp/bloom-update-pending` is written by `bootstrap-machine.sh update` before it restarts the
# service, and deleted by a runner that gets as far as listening. It holds the version asked for,
# the version that was current before, and how many starts have seen it:
#
#   1.29.0
#   1.28.4
#   2
#
# **The count is what makes this a record of attempts rather than of an intention.** One start on
# the new release is not a failure: a machine can be restarted for its own reasons a second after an
# update, and rolling back then would undo a release that was fine. The second start that still
# finds the same version current, with the marker still there, is the one that gives up on it.
#
# **A rollback that cannot be done runs the new version anyway.** If the previous release is gone or
# the symlink cannot be written, this execs what it has and lets the health check stay red: a
# machine answering wrongly can be looked at, and a machine answering nothing cannot.
set -eu

prefix="${BLOOM_PREFIX:-/opt/bloom}"
marker="${BLOOM_UPDATE_MARKER:-/var/tmp/bloom-update-pending}"
here="$(dirname "$0")"
runner="$here/bloom-runner-exec"

note() {
    echo "bloom-runner: $*" >&2
}

# Only a serve is a start worth deciding about. `version`, `git-credential` and `gh-token` are
# called by other processes on the machine, many times, and have nothing to do with a release.
if [ "${1:-}" = "serve" ] && [ -f "$marker" ]; then
    asked="$(sed -n 1p "$marker" 2>/dev/null || true)"
    previous="$(sed -n 2p "$marker" 2>/dev/null || true)"
    starts="$(sed -n 3p "$marker" 2>/dev/null || true)"
    case "$starts" in
    ''|*[!0-9]*) starts=0 ;;
    esac
    current="$(basename "$(readlink "$prefix/current" 2>/dev/null || echo "")" 2>/dev/null || true)"

    if [ -n "$asked" ] && [ "$asked" = "$current" ]; then
        starts=$((starts + 1))
        if [ "$starts" -ge 2 ] && [ -n "$previous" ] && [ -x "$prefix/$previous/bin/bloom-runner" ]; then
            note "$asked did not come up on two starts; going back to $previous"
            # `ln -sfn` rather than the bootstrap's `mv -T`, which is GNU only: this script is
            # also run by a probe on a Mac, and a rollback that quietly does nothing there would
            # be a rollback nobody tests.
            if ln -sfn "$prefix/$previous" "$prefix/current" 2>/dev/null; then
                rm -f "$marker"
                exec "$prefix/current/bin/bloom-runner" "$@"
            fi
            note "could not put $previous back, so $asked runs and its health check stays red"
        else
            printf '%s\n%s\n%s\n' "$asked" "$previous" "$starts" > "$marker" 2>/dev/null || true
        fi
    else
        # The marker is about a release this machine is no longer on.
        rm -f "$marker"
    fi
fi

exec "$runner" "$@"

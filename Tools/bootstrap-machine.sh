#!/usr/bin/env bash
# Installs or updates bloom-runner on a Cloud workspace's machine.
#
# runbloom.app does the first install itself, with a script of its own that unpacks the same
# archive into the same place and creates the `bloom` service; `update` here is what the machine
# runs when runbloom.app's `control/update` call asks it to move to another release, and `install`
# is kept for development machines set up by hand.
#
#   bootstrap-machine.sh install <version> <sha256> [tag]
#   bootstrap-machine.sh update  <version> <sha256> [tag]
#
# runbloom.app runs this as the machine's user, with the script itself on stdin
# (`bash -s -- install 1.29.0 <sha256>`), after writing /etc/bloom/workspace.json through the
# provider's filesystem API. Nothing secret is passed here: the version and the checksum of the
# release asset are the whole of what it is told.
#
# 1. Download bloom-runner-linux-x86_64-<version>.tar.gz from the bloom repository's GitHub
#    release under the tag given, or v<version> without one, and refuse it unless its sha256 is
#    the one given. The tag is v<version> or runner-v<version> (a runner-only test release) and
#    nothing else, so it can only ever name this version in this repository.
# 2. Unpack it into /opt/bloom/<version>, and point /opt/bloom/current at that.
# 3. On install, create the `bloom` service once. On update, restart it and wait to see the new
#    version answer /_bloom/health. It does not put the symlink back itself: the restart it asks
#    for kills this script, so a revert written here would be a revert nobody runs.
#
# **Two things undo a release that will not start, and this is neither of them.** The machine's own
# half is the start wrapper in bin/bloom-runner, which the supervisor re-runs about once a minute
# and which goes back to the previous version on the second start that still finds the new one
# current (Tools/runner-start.sh). The control plane's half is runbloom.app, which polls health and
# reaches in through the provider when the machine has not healed itself. Both write the same
# symlink and both are safe to run twice. If a third ever arrives, say so here.
#
# **The service's command never changes**, because creating a service under a name that exists
# silently keeps the old definition (measured on a Sprite). It always runs
# /opt/bloom/current/bin/bloom-runner, and an update moves the symlink underneath it.
#
# **Never delete /opt/bloom/<previous version>.** Both reverts above put the symlink back to a
# directory that is already on the machine, downloading nothing, which is what makes them work when
# the network or the disk is what went wrong. Anything added here that prunes old versions has to
# keep at least the one `current` pointed at before the last update.
#
# **When BLOOM_DOWNLOAD_URL is set, the archive comes from exactly there.** The repository is private
# since 19 September 2026, so the release URL built from the tag refuses a machine. runbloom.app
# resolves the asset with its own credential and hands over a short-lived signed URL, which
# `MachineUpdate` puts in this script's environment rather than its arguments. It is fetched over
# https with no redirect followed, never printed, and the sha256 above still decides. A refusal says
# the URL may have expired and stops: runbloom.app sends a fresh one, and this does not retry the old.
#
# Environment:
#   BLOOM_DOWNLOAD_URL  a signed URL for the archive, from runbloom.app's control/update
#
# Environment, for development and tests only:
#   BLOOM_RELEASE_BASE  where releases are downloaded from (default the bloom repository on GitHub)
#   BLOOM_PREFIX        where versions are unpacked (default /opt/bloom)
#   BLOOM_SERVICE_TOOL  the provider's service command (default sprite-env)
#   BLOOM_HEALTH_URL    what an update waits on (default http://127.0.0.1:8081/_bloom/health)
#   BLOOM_UPDATE_MARKER the file a new server deletes once it listens (default /var/tmp/bloom-update-pending)

set -euo pipefail

action="${1:-}"
version="${2:-}"
checksum="${3:-}"
tag="${4:-v$version}"
release_base="${BLOOM_RELEASE_BASE:-https://github.com/spatie/bloom/releases/download}"
prefix="${BLOOM_PREFIX:-/opt/bloom}"
service_tool="${BLOOM_SERVICE_TOOL:-sprite-env}"
health_url="${BLOOM_HEALTH_URL:-http://127.0.0.1:8081/_bloom/health}"

fail() {
  echo "bootstrap-machine: $*" >&2
  exit 1
}

case "$action" in
  install | update) ;;
  *) fail "usage: bootstrap-machine.sh install|update <version> <sha256> [tag]" ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "not a release version: $version"
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || fail "not a sha256: $checksum"
[[ "$tag" == "v$version" || "$tag" == "runner-v$version" ]] || fail "not a tag for $version: $tag"

# /opt is root's. The machine's user has passwordless sudo, which is what makes this one exec enough.
sudo_if_needed() {
  if [[ -w "$(dirname "$prefix")" || -w "$prefix" ]]; then "$@"; else sudo "$@"; fi
}

asset="bloom-runner-linux-x86_64-${version}.tar.gz"
target="$prefix/$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ ! -x "$target/bin/bloom-runner" ]]; then
  if [[ -n "${BLOOM_DOWNLOAD_URL:-}" ]]; then
    # No --location: a signed asset URL answers the file itself, and anything else is refused
    # rather than followed. The URL is a bearer URL, so no message here repeats it.
    status="$(curl --silent --show-error --proto =https --retry 3 --output "$work/$asset" \
      --write-out '%{http_code}' "$BLOOM_DOWNLOAD_URL")" || fail "could not download $asset"
    [[ "$status" == "200" ]] ||
      fail "the download URL for $asset was refused with HTTP $status; it may have expired, so ask runbloom.app for a fresh one"
  else
    curl --fail --silent --show-error --location --retry 3 --output "$work/$asset" "$release_base/$tag/$asset"
  fi
  actual="$(sha256sum "$work/$asset" | cut -d' ' -f1)"
  [[ "$actual" == "$checksum" ]] || fail "$asset has sha256 $actual, not $checksum"
  mkdir -p "$work/unpacked"
  tar -xzf "$work/$asset" -C "$work/unpacked"
  # bin/, lib/ and licences/ sit at the root of the archive, which is the layout runbloom.app's own
  # first install unpacks too.
  unpacked="$work/unpacked"
  [[ -x "$unpacked/bin/bloom-runner" ]] || fail "$asset has no bin/bloom-runner"
  sudo_if_needed mkdir -p "$prefix"
  sudo_if_needed rm -rf "$target.partial"
  sudo_if_needed cp -a "$unpacked" "$target.partial"
  sudo_if_needed mv "$target.partial" "$target"
fi

# The version, not the path `readlink` gives: the marker is read by the start wrapper and by
# runbloom.app, and one convention for both beats two writers and every reader taking either.
previous=""
[[ -L "$prefix/current" ]] && previous="$(basename "$(readlink "$prefix/current")")"

# A new symlink moved over the old one with rename, so there is never a moment with none.
#
# Three ways to ask for that one rename, because the flag that spells it is not the same everywhere
# and `mv` without it moves the new link *into* the directory the old one points at: `-T` is GNU's,
# `-h` is BSD's, and `os.replace` is the rename itself, from a python3 the machine already has. Only
# if all three are missing does it fall back to `ln -sfn`, which unlinks and re-creates and so has a
# moment with no `current` at all. Nothing we ship to reaches that line; it is there so an image
# none of us has tried still ends up pointing somewhere.
point_current_at() {
  sudo_if_needed ln -sfn "$1" "$prefix/current.next"
  if sudo_if_needed mv -T "$prefix/current.next" "$prefix/current" 2>/dev/null ||
    sudo_if_needed mv -h "$prefix/current.next" "$prefix/current" 2>/dev/null ||
    sudo_if_needed python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' \
      "$prefix/current.next" "$prefix/current" 2>/dev/null; then
    return 0
  fi
  sudo_if_needed rm -f "$prefix/current.next"
  sudo_if_needed ln -sfn "$1" "$prefix/current"
}

point_current_at "$target"

# The sandbox user, made or checked at every install and update, beside the version just unpacked.
# **A failure here is not a failure of the update**: a machine whose provider will not make a user
# runs everything as the Runner's user, as it did before the sandbox existed, and the Runner asks
# `MachineSandbox.available` rather than assuming. The log says what happened either way.
provision="$target/bin/provision-sandbox.sh"
if [[ -x "$provision" ]]; then
  BLOOM_WORKTREE="${BLOOM_WORKTREE:-$HOME/workspace}" BLOOM_DATA_DIR="${BLOOM_DATA_DIR:-$HOME/.bloom}" \
    bash "$provision" || echo "bootstrap-machine: the sandbox user could not be made; running as $(id -un)" >&2
fi

if [[ "$action" == "install" ]]; then
  # The whole name, so a service called bloom-something does not count as this one.
  if ! "$service_tool" services list 2>/dev/null | grep -qE '(^|[^[:alnum:]_-])bloom([^[:alnum:]_-]|$)'; then
    "$service_tool" services create bloom --cmd "$prefix/current/bin/bloom-runner" --args serve --http-port 8080 --no-stream
  else
    "$service_tool" services restart bloom
  fi
  echo "bloom-runner $version installed"
  exit 0
fi

# The restart ends the server that started this script. bloom-runner launches it with setsid, and
# writes nothing here; the marker below is how the new server says it came up, by deleting it once
# it is listening, so the rollback does not depend on this script outliving the restart. Whether a
# setsid child does outlive a Sprite service restart is checked on a bloomdev machine.
# In /var/tmp rather than beside the versions, because /opt is root's and the server deleting it is
# the machine's own user.
marker="${BLOOM_UPDATE_MARKER:-/var/tmp/bloom-update-pending}"
# Three lines: the version asked for, the version to go back to, and how many starts have seen this
# marker. The start wrapper in bin/bloom-runner counts those and gives up on the release that does
# not come up (Tools/runner-start.sh), and runbloom.app reads the same file when it reaches into a
# machine that has not healed, so that a bad night reads as "19 starts on 0.2.0, going back to
# 0.1.9" rather than as silence. Changing this shape changes what that reader sees. Its absence is
# the normal case, not an error.
printf '%s\n%s\n0\n' "$version" "$previous" > "$marker"
"$service_tool" services restart bloom >/dev/null 2>&1 &
for _ in $(seq 1 20); do
  if [[ ! -e "$marker" ]]; then
    echo "bloom-runner updated to $version"
    exit 0
  fi
  if curl --fail --silent --max-time 2 "$health_url" | grep -q "\"$version\""; then
    rm -f "$marker"
    echo "bloom-runner updated to $version"
    exit 0
  fi
  sleep 1
done

# Not seen to come up. The marker stays: it is what the start wrapper counts, and deleting it here
# would take away the machine's own way back. See the note at the head of this file about who
# reverts.
fail "$version did not answer $health_url within 20 seconds; the machine goes back to $previous at its next start"

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
# 3. On install, create the `bloom` service once. On update, restart it, and if the new version
#    does not answer /_bloom/health within 20 seconds, point the symlink back and restart again.
#
# **The service's command never changes**, because creating a service under a name that exists
# silently keeps the old definition (measured on a Sprite). It always runs
# /opt/bloom/current/bin/bloom-runner, and an update moves the symlink underneath it.
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
  curl --fail --silent --show-error --location --retry 3 --output "$work/$asset" "$release_base/$tag/$asset"
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

previous=""
[[ -L "$prefix/current" ]] && previous="$(readlink "$prefix/current")"

# A new symlink moved over the old one with rename, so there is never a moment with none.
sudo_if_needed ln -sfn "$target" "$prefix/current.next"
sudo_if_needed mv -T "$prefix/current.next" "$prefix/current"

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
printf '%s\n%s\n' "$version" "$previous" > "$marker"
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

rm -f "$marker"
if [[ -n "$previous" ]]; then
  sudo_if_needed ln -sfn "$previous" "$prefix/current.next"
  sudo_if_needed mv -T "$prefix/current.next" "$prefix/current"
  "$service_tool" services restart bloom
  fail "$version did not answer $health_url within 20 seconds; went back to $previous"
fi
fail "$version did not answer $health_url within 20 seconds, and there was nothing to go back to"

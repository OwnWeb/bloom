#!/usr/bin/env bash
# Boots a packaged Bloom Runner on a host built to be a Cloud workspace's machine rather than a
# convenient one, and says whether it would serve.
#
# **Every Runner fault of 21 September 2026 was hidden by the smoke being kinder than production.**
# Four workspaces in a row failed to start, each behind the last, and `packaged-runner` was green
# through all of them, because the job it runs in differs from a Sprite in exactly the three ways
# that mattered:
#
#   1. It runs `--privileged`, so root has CAP_SYS_PTRACE. A Sprite does not grant it, `setuid`
#      clears a process's dumpable flag, and `/proc/<pid>/exe` of a process that is not dumpable
#      cannot be read without that capability. The sandbox supervisor could identify no exec at all
#      and refused every launch.
#   2. It compiles a fake gh to `/usr/bin/gh`, the one path a Sprite does not use: gh lives in
#      `/.sprite/bin`. The Runner required the former and refused to start.
#   3. It runs `provision-sandbox.sh` from the workflow, so it never noticed that installing a
#      Runner on a new machine did not. Five directories and the credential shield were missing on
#      every machine ever created.
#
# So this does none of those. The capability set is a Sprite's, measured from one: Docker's default
# plus SYS_ADMIN and NET_ADMIN is the same sixteen, and SYS_PTRACE is absent from both. gh is put
# where a Sprite keeps it and nowhere else. The sandbox is provisioned by whatever the package does
# when it is installed, not by this script, because that is the thing being tested.
#
# It is not a Sprite and does not claim to be. It is a host that refuses the same things one does.
#
#   Tools/sprite-smoke.sh <package.tar.gz>
#   Tools/sprite-smoke.sh --tag runner-v0.1.0-test.37
#
# Needs Docker on x86_64 Linux. The package is x86_64, and an emulated arm64 host answers
# differently about ptrace and namespaces, which are the whole subject here.
set -euo pipefail

image="${SPRITE_SMOKE_IMAGE:-ubuntu:26.04}"
package=""
tag=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) package="$1"; shift ;;
  esac
done

if [[ -z "$package" && -z "$tag" ]]; then
  echo "Give a package tarball or --tag runner-v<version>." >&2
  exit 64
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "This needs an x86_64 host: the package is x86_64 and emulation answers differently about" >&2
  echo "ptrace and namespaces, which is what this exists to check." >&2
  exit 64
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -n "$tag" ]]; then
  echo "==> fetching $tag"
  gh release download "$tag" --repo spatie/bloom --pattern '*.tar.gz' --dir "$work"
  gh release download "$tag" --repo spatie/bloom --pattern '*.sha256' --dir "$work"
  (cd "$work" && sha256sum --check --quiet ./*.sha256)
  package="$(ls "$work"/*.tar.gz)"
fi

package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"

echo "==> booting $(basename "$package") on a host with a Sprite's capabilities"

# SYS_ADMIN and NET_ADMIN on top of Docker's default is a Sprite's set exactly. SYS_PTRACE is
# deliberately not added: its absence is the whole point, and adding it would make this the test
# that already exists.
docker run --rm \
  --cap-add SYS_ADMIN \
  --cap-add NET_ADMIN \
  --security-opt apparmor=unconfined \
  --cgroupns host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$package":/tmp/runner.tar.gz:ro \
  -v "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)":/bloom:ro \
  "$image" \
  bash -euo pipefail -c '
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 openssl git gh ca-certificates sudo util-linux tmux >/dev/null

    echo "--> capabilities here, which must not include sys_ptrace"
    capsh --decode="$(grep ^CapEff /proc/self/status | cut -f2)" | tr "," "\n" | grep -c sys_ptrace && {
      echo "This host has CAP_SYS_PTRACE and a Cloud workspace machine does not, so it proves nothing." >&2
      exit 1
    } || true

    # Where a Sprite keeps gh, and nowhere else. The Runner has to find it rather than be told.
    install -d -o root -g root /.sprite/bin
    mv "$(command -v gh)" /.sprite/bin/gh
    ln -sf /.sprite/bin/gh /usr/local/bin/gh-for-humans

    # The provider socket the sandbox masks before it runs anything untrusted.
    install -d /.sprite
    python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind(\"/.sprite/api.sock\"); s.listen()" &
    for _ in $(seq 1 50); do [ -S /.sprite/api.sock ] && break; sleep 0.1; done
    [ -S /.sprite/api.sock ]

    # uid 1001, which is what a machine runs the Runner as.
    useradd --uid 1001 --create-home --shell /bin/bash sprite
    echo "sprite ALL=(ALL) NOPASSWD:SETENV: ALL" >/etc/sudoers.d/sprite
    chmod 0440 /etc/sudoers.d/sprite

    version="$(basename /tmp/runner.tar.gz | sed -E "s/^bloom-runner-linux-x86_64-(.*)\.tar\.gz$/\1/")"
    install -d -o root -g root "/opt/bloom/${version}"
    tar -xzf /tmp/runner.tar.gz -C "/opt/bloom/${version}"
    ln -sfn "/opt/bloom/${version}" /opt/bloom/current

    # Installed the way runbloom.app installs it, provisioning included, because a first install
    # that does not provision is one of the faults this exists to catch.
    echo "--> provisioning, as the install does"
    runuser -u sprite -- env HOME=/home/sprite BLOOM_WORKTREE=/home/sprite/workspace \
      BLOOM_DATA_DIR=/home/sprite/.bloom bash /opt/bloom/current/bin/provision-sandbox.sh

    echo "--> booting the packaged Runner against a fake runbloom.app"
    cp -r /bloom/Tools /tmp/tools
    chown -R sprite:sprite /tmp/tools
    cd /tmp/tools
    runuser -u sprite -- env HOME=/home/sprite python3 /tmp/tools/runner-smoke.py /opt/bloom/current/bin/bloom-runner
  '

echo "==> a machine built like a Sprite runs this package"

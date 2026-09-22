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
#   Tools/sprite-smoke.sh --from-source
#
# The first two need Docker on x86_64 Linux: the package is x86_64, and an emulated arm64 host
# answers differently about ptrace and namespaces, which are the whole subject here.
#
# `--from-source` is the loop to actually work in, and runs anywhere Docker does, natively. It
# builds the Runner for this architecture into a cached volume and boots that instead of a
# package, so a change is measured in about two minutes rather than in a seventeen minute release
# somebody is waiting on. It also names a repository that exists, so setup performs its real
# clone and the smoke goes on to commit and push through the hardened git. Every Runner fault of
# 21 September 2026 was in that sequence, and the smoke of the day ran none of it.
set -euo pipefail

image="${SPRITE_SMOKE_IMAGE:-ubuntu:26.04}"
package=""
tag=""
from_source=""
volume="${SPRITE_SMOKE_VOLUME:-bloom-linux-build}"
swift_image="${SPRITE_SMOKE_SWIFT_IMAGE:-swift:6.3.3-noble@sha256:8de8ea332a61e961ead4ef41029c2552b18e1a70dd5942d25ecf7d8de2eec5b5}"
# Empty means the smoke keeps to itself and clones nothing. Name a repository that
# exists and setup performs its real clone, and the commit and push are checked too;
# a private one needs BLOOM_SMOKE_GITHUB_TOKEN, which the fake runbloom.app then serves.
repository="${BLOOM_SMOKE_REPOSITORY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="$2"; shift 2 ;;
    --from-source) from_source=1; shift ;;
    --image) image="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) package="$1"; shift ;;
  esac
done

if [[ -z "$package" && -z "$tag" && -z "$from_source" ]]; then
  echo "Give a package tarball, --tag runner-v<version>, or --from-source." >&2
  exit 64
fi

if [[ -z "$from_source" && "$(uname -m)" != "x86_64" ]]; then
  echo "This needs an x86_64 host: the package is x86_64 and emulation answers differently about" >&2
  echo "ptrace and namespaces, which is what this exists to check." >&2
  exit 64
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

if [[ -n "$from_source" ]]; then
  # A worktree's `.git` is a file pointing outside any bind mount, so the sources are exported
  # rather than mounted. `git archive` takes what is committed; the uncommitted edits are what a
  # person is usually testing, so those are laid over the top.
  source="$work/src"
  mkdir -p "$source"
  git -C "$root" archive HEAD | tar -x -C "$source"
  git -C "$root" diff HEAD --binary >"$work/local.patch"
  if [[ -s "$work/local.patch" ]]; then
    if ! (cd "$source" && git apply --whitespace=nowarn "$work/local.patch"); then
      echo "    uncommitted edits did not apply, so this is HEAD as it stands" >&2
    fi
  fi

  echo "==> building the Runner for $(uname -m) in $swift_image"
  docker run --rm -v "$source":/src -v "$volume":/build "$swift_image" bash -euo pipefail -c '
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq libsqlite3-dev >/dev/null 2>&1
    cd /src && swift build --product bloom-runner --scratch-path /build
  '

  cat >"$work/inside.sh" <<'INSIDE'
set -euo pipefail
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends python3 openssl git gh ca-certificates sudo util-linux tmux clang >/dev/null 2>&1

echo "--> capabilities here: $(grep ^CapEff /proc/self/status | cut -f2)  (a Sprite is 00000000a82435fb)"
if capsh --decode="$(grep ^CapEff /proc/self/status | cut -f2)" 2>/dev/null | tr "," "\n" | grep -q sys_ptrace; then
  echo "This host has CAP_SYS_PTRACE and a Cloud workspace machine does not, so it proves nothing." >&2
  exit 1
fi

# Where a Sprite keeps gh, and nowhere else.
install -d -o root -g root /.sprite/bin
mv "$(command -v gh)" /.sprite/bin/gh

# The provider socket the sandbox masks before it runs anything untrusted.
python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('/.sprite/api.sock'); s.listen()" &
for _ in $(seq 1 50); do [ -S /.sprite/api.sock ] && break; sleep 0.1; done
[ -S /.sprite/api.sock ]

useradd --uid 1001 --create-home --shell /bin/bash sprite
echo "sprite ALL=(ALL) NOPASSWD:SETENV: ALL" >/etc/sudoers.d/sprite
chmod 0440 /etc/sudoers.d/sprite

install -o root -g root -m 0755 /build/*/debug/bloom-runner /usr/local/bin/bloom-runner
clang -shared -fPIC -O2 -o /usr/local/lib/bloom-credential-shield.so /src/Sources/BloomCredentialShield/shield.c
chown root:root /usr/local/lib/bloom-credential-shield.so
chmod 0555 /usr/local/lib/bloom-credential-shield.so

echo "--> provisioning the sandbox, as installing the package does"
runuser -u sprite -- env HOME=/home/sprite BLOOM_WORKTREE=/home/sprite/workspace \
  BLOOM_DATA_DIR=/home/sprite/.bloom bash /src/Tools/provision-sandbox.sh

cp -r /src/Tools /tmp/tools
chown -R sprite:sprite /tmp/tools
# An untrusted gh ahead of the real one on PATH, because the Runner must find its own.
install -d -o sprite -g sprite /tmp/untrusted-bin
cp /bin/false /tmp/untrusted-bin/gh

echo "--> booting the Runner against a fake runbloom.app"
runuser -u sprite -- env HOME=/home/sprite PATH="/tmp/untrusted-bin:$PATH" \
  BLOOM_SMOKE_WORKTREE=/home/sprite/workspace \
  BLOOM_SMOKE_REPOSITORY="${BLOOM_SMOKE_REPOSITORY:-}" \
  BLOOM_SMOKE_BRANCH="${BLOOM_SMOKE_BRANCH:-}" \
  BLOOM_SMOKE_BASE_BRANCH="${BLOOM_SMOKE_BASE_BRANCH:-}" \
  BLOOM_SMOKE_PUSH="${BLOOM_SMOKE_PUSH:-}" \
  BLOOM_SMOKE_GITHUB_TOKEN="${BLOOM_SMOKE_GITHUB_TOKEN:-}" \
  python3 /tmp/tools/runner-smoke.py /usr/local/bin/bloom-runner
INSIDE

  echo "==> booting it on a host with a Sprite's capabilities"
  docker run --rm \
    --cap-add SYS_ADMIN \
    --cap-add NET_ADMIN \
    --security-opt apparmor=unconfined \
    --cgroupns host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$source":/src:ro \
    -v "$volume":/build:ro \
    -v "$work/inside.sh":/inside.sh:ro \
    -e BLOOM_SMOKE_REPOSITORY="$repository" \
    -e BLOOM_SMOKE_BRANCH="${BLOOM_SMOKE_BRANCH:-}" \
    -e BLOOM_SMOKE_BASE_BRANCH="${BLOOM_SMOKE_BASE_BRANCH:-}" \
    -e BLOOM_SMOKE_PUSH="${BLOOM_SMOKE_PUSH:-}" \
    -e BLOOM_SMOKE_GITHUB_TOKEN="${BLOOM_SMOKE_GITHUB_TOKEN:-}" \
    "$swift_image" bash /inside.sh

  echo "==> a machine built like a Sprite runs the Runner built from these sources"
  exit 0
fi

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

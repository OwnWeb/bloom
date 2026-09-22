#!/usr/bin/env bash
# The sequence setup performs, which no smoke covered: remove the worktree, put it back the way
# makeSharedWorktree does, clone into it as the agent, then have the Runner work in it. Twice,
# because setup runs again and the second time has to delete the first clone.
set -uo pipefail
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends git sudo clang ca-certificates >/dev/null 2>&1
useradd --uid 1001 --create-home --shell /bin/bash sprite
echo 'sprite ALL=(ALL) NOPASSWD:SETENV: ALL' >/etc/sudoers.d/sprite && chmod 0440 /etc/sudoers.d/sprite
clang -shared -fPIC -O2 -o /usr/local/lib/bloom-credential-shield.so /src/Sources/BloomCredentialShield/shield.c 2>/dev/null
chmod 0555 /usr/local/lib/bloom-credential-shield.so
runuser -u sprite -- env HOME=/home/sprite BLOOM_WORKTREE=/home/sprite/workspace \
  BLOOM_DATA_DIR=/home/sprite/.bloom bash /src/Tools/provision-sandbox.sh >/dev/null

w=/home/sprite/workspace
failures=0
agent() { runuser -u bloom-agent -- bash -c "umask 002; $*"; }
runner() { runuser -u sprite -- bash -c "umask 002; $*"; }

for round in 1 2; do
  echo "round $round:"
  if runner "rm -rf $w && mkdir -p $w && chgrp bloom-work $w && chmod 2770 $w"; then
    echo "  ok      runner remade the worktree"
  else
    echo "  FAILED  runner could not remake the worktree"; failures=$((failures + 1))
  fi

  ownership=$(stat -c "%U:%G %a" "$w")
  echo "  worktree: $ownership"

  if agent "git clone -q https://github.com/octocat/Hello-World.git $w"; then
    echo "  ok      agent cloned into it"
  else
    echo "  FAILED  agent could not clone"; failures=$((failures + 1))
  fi

  if runner "git -C $w status --short" >/dev/null; then
    echo "  ok      runner runs git in it"
  else
    echo "  FAILED  runner cannot run git"; failures=$((failures + 1))
  fi

  if agent "echo x >> $w/README && git -C $w -c user.name=a -c user.email=a@b commit -qam agent"; then
    echo "  ok      agent commits"
  else
    echo "  FAILED  agent cannot commit"; failures=$((failures + 1))
  fi

  if runner "echo y >> $w/README && git -C $w -c user.name=r -c user.email=r@b commit -qam runner"; then
    echo "  ok      runner commits over it"
  else
    echo "  FAILED  runner cannot commit"; failures=$((failures + 1))
  fi
done

echo
if (( failures )); then
  echo "$failures failed"
  exit 1
fi
echo "the whole clone cycle holds, twice"

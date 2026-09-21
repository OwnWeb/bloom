#!/bin/zsh
# What Tools/runner-start.sh decides, driven against a temporary /opt/bloom of its own.
#
# A shell script gets a shell test: the wrapper is what runs before anything Swift does, and the
# case it exists for is a release whose binary cannot start at all, which no Swift test can stand in
# for. Run by the lint job beside the other script checks.
set -euo pipefail
cd "$(dirname "$0")/.."

wrapper="$PWD/Tools/runner-start.sh"
root="$(mktemp -d "${TMPDIR:-/tmp}/bloom-start-probe.XXXXXX")"
trap 'rm -rf "$root"' EXIT
prefix="$root/opt"
marker="$root/marker"
failures=()

fake_release() {
  local version="$1" outcome="$2"
  mkdir -p "$prefix/$version/bin"
  cp "$wrapper" "$prefix/$version/bin/bloom-runner"
  printf '#!/bin/sh\necho "%s ran $*" >> "%s/ran.log"\nexit %s\n' "$version" "$root" "$outcome" \
    > "$prefix/$version/bin/bloom-runner-exec"
  chmod +x "$prefix/$version/bin/bloom-runner" "$prefix/$version/bin/bloom-runner-exec"
}

point_at() {
  ln -sfn "$prefix/$1" "$prefix/current"
}

start() {
  BLOOM_PREFIX="$prefix" BLOOM_UPDATE_MARKER="$marker" BLOOM_UPDATE_LOG="$root/update.log" \
    "$prefix/current/bin/bloom-runner" "$@" 2>>"$root/stderr.log" || true
}

check() {
  local what="$1" expected="$2" actual="$3"
  [[ "$expected" == "$actual" ]] || failures+=("$what: expected $expected, got $actual")
}

fake_release 1.0.0 0
fake_release 1.1.0 1
point_at 1.1.0
printf '1.1.0\n1.0.0\n0\n' > "$marker"

# The first start on a new release runs it: one restart is not a failure.
start serve
check "first start runs the new release" "1.1.0 ran serve" "$(tail -n 1 "$root/ran.log")"
check "the first start is counted" "1" "$(sed -n 3p "$marker")"

# The second start that still finds it current gives up on it and goes back.
start serve
check "the second start rolls back" "1.0.0 ran serve" "$(tail -n 1 "$root/ran.log")"
check "the symlink moved" "$prefix/1.0.0" "$(readlink "$prefix/current")"
check "the marker is gone" "no" "$([[ -f "$marker" ]] && echo yes || echo no)"

# Anything but a serve is none of its business, even with a marker sitting there.
point_at 1.1.0
printf '1.1.0\n1.0.0\n1\n' > "$marker"
start version
check "version does not roll back" "1.1.0 ran version" "$(tail -n 1 "$root/ran.log")"
check "version leaves the count alone" "1" "$(sed -n 3p "$marker")"

# A marker about a release this machine is no longer on is forgotten rather than acted on.
point_at 1.0.0
printf '1.1.0\n1.0.0\n5\n' > "$marker"
start serve
check "an old marker is dropped" "no" "$([[ -f "$marker" ]] && echo yes || echo no)"
check "and the current release runs" "1.0.0 ran serve" "$(tail -n 1 "$root/ran.log")"

# With nothing to go back to, the new release runs anyway: answering wrongly beats answering nothing.
rm -rf "$prefix/1.0.0"
point_at 1.1.0
printf '1.1.0\n1.0.0\n1\n' > "$marker"
start serve
check "a rollback that cannot be done runs the new release" "1.1.0 ran serve" "$(tail -n 1 "$root/ran.log")"

# --- bootstrap-machine.sh, whose symlink moves are the other half of the same rollback ---
#
# It is driven against a release served from a directory (curl reads file:// happily), with a fake
# service tool and a health URL nothing answers, so the update path runs to its own rollback.
bootstrap="$PWD/Tools/bootstrap-machine.sh"
releases="$root/releases"
mkdir -p "$releases/v2.0.0" "$releases/v2.1.0" "$root/fake-bin"
build_release() {
  local version="$1"
  local outcome="$2"
  # Separate lines: zsh expands the whole `local` before it assigns any of it, so a later value
  # cannot read an earlier one on the same line.
  local stage="$root/stage-$version"
  rm -rf "$stage"
  mkdir -p "$stage/bin"
  cp "$wrapper" "$stage/bin/bloom-runner"
  printf '#!/bin/sh\necho "%s ran $*" >> "%s/ran.log"\nexit %s\n' "$version" "$root" "$outcome" > "$stage/bin/bloom-runner-exec"
  chmod +x "$stage/bin/bloom-runner" "$stage/bin/bloom-runner-exec"
  tar -czf "$releases/v$version/bloom-runner-linux-x86_64-$version.tar.gz" -C "$stage" bin
  shasum -a 256 "$releases/v$version/bloom-runner-linux-x86_64-$version.tar.gz" | cut -d' ' -f1
}
printf '#!/bin/sh\necho "service $*" >> "%s/service.log"\n' "$root" > "$root/fake-bin/fake-service"
chmod +x "$root/fake-bin/fake-service"

sum_200="$(build_release 2.0.0 0)"
sum_210="$(build_release 2.1.0 1)"
bootstrap_prefix="$root/bootstrap-opt"
run_bootstrap() {
  BLOOM_RELEASE_BASE="file://$releases" BLOOM_PREFIX="$bootstrap_prefix" BLOOM_SERVICE_TOOL="$root/fake-bin/fake-service" \
    BLOOM_HEALTH_URL="http://127.0.0.1:9/_bloom/health" BLOOM_UPDATE_MARKER="$root/bootstrap-marker" \
    bash "$bootstrap" "$@" >>"$root/bootstrap.log" 2>&1 || true
}

run_bootstrap install 2.0.0 "$sum_200"
check "install points current at the version" "$bootstrap_prefix/2.0.0" "$(readlink "$bootstrap_prefix/current")"
check "install creates the service once" "1" "$(grep -c 'services create bloom' "$root/service.log" || true)"

# A checksum that does not match is refused before anything is unpacked.
run_bootstrap install 9.9.9 "$(printf '%064d' 0)"
check "a release with the wrong sha256 is not installed" "no" "$([[ -d "$bootstrap_prefix/9.9.9" ]] && echo yes || echo no)"

# A signed download URL is used instead of the release base, over https only, and never printed:
# plain http is refused outright, which also shows the release base was not what got fetched.
secret_url="http://127.0.0.1:9/signed?token=do-not-print-me"
BLOOM_DOWNLOAD_URL="$secret_url" run_bootstrap install 2.0.1 "$sum_200"
check "a download_url that is not https installs nothing" "no" "$([[ -d "$bootstrap_prefix/2.0.1" ]] && echo yes || echo no)"
check "the download_url is never written to the log" "0" "$(grep -c 'do-not-print-me' "$root/bootstrap.log" || true)"

# An update to a release that never answers: the script moves the symlink and leaves the marker for
# the start wrapper, because the restart it asks for is what kills this script. The revert is the
# wrapper's, and the checks above already cover it.
run_bootstrap update 2.1.0 "$sum_210"
check "the update moved current to the new version" "$bootstrap_prefix/2.1.0" "$(readlink "$bootstrap_prefix/current")"
check "current is still a symlink, not a directory" "yes" "$([[ -L "$bootstrap_prefix/current" ]] && echo yes || echo no)"
check "nothing was left beside it" "no" "$([[ -e "$bootstrap_prefix/current.next" ]] && echo yes || echo no)"
check "the marker is left for the wrapper" "2.1.0" "$(sed -n 1p "$root/bootstrap-marker" 2>/dev/null || true)"
check "with the version to go back to, as a bare version" "2.0.0" "$(sed -n 2p "$root/bootstrap-marker" 2>/dev/null || true)"

# A marker from an older bootstrap, whose line 2 is a path rather than a version, still works: a
# machine can be updated by a bootstrap older than the wrapper it installs.
point_at 1.1.0
printf '1.1.0\n%s\n1\n' "$prefix/1.0.0" > "$marker"
fake_release 1.0.0 0
start serve
check "a marker written the old way still rolls back" "$prefix/1.0.0" "$(readlink "$prefix/current")"

# And the wrapper, handed that marker, is what actually goes back.
for _ in 1 2; do
  BLOOM_PREFIX="$bootstrap_prefix" BLOOM_UPDATE_MARKER="$root/bootstrap-marker" BLOOM_UPDATE_LOG="$root/update.log" \
    "$bootstrap_prefix/current/bin/bloom-runner" serve 2>/dev/null || true
done
check "the wrapper goes back to the release that worked" "$bootstrap_prefix/2.0.0" "$(readlink "$bootstrap_prefix/current")"
# Three by now: the two rollbacks earlier in this probe and this one. What matters is that the file
# keeps them all, so a machine carries its history of rollbacks rather than only its last attempt.
check "and says so where a person will find it afterwards" "3" \
  "$(grep -c 'going back to' "$root/update.log" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------- provisioning the sandbox user
#
# Tools/provision-sandbox.sh needs root, so it is run with SUDO pointed at a recorder: nothing is
# changed, and what it would have done is read back. What matters is that the sandbox user is made
# with no sudo of its own, that the sudoers line is checked with visudo before it is installed, that
# the CLIs are copied somewhere world-readable, and that the Runner's data directory stays private.
provision_script="$PWD/Tools/provision-sandbox.sh"
sandbox_root="$root/sandbox"
mkdir -p "$sandbox_root/home/.claude" "$sandbox_root/home/.local/share/sprite-agents/claude" "$sandbox_root/worktree" "$sandbox_root/home/.bloom"
print -r -- '{}' > "$sandbox_root/home/.claude/settings.json"
print -r -- 'binary' > "$sandbox_root/home/.local/share/sprite-agents/claude/claude"
print -r -- 'shield' > "$sandbox_root/credential-shield.so"
printf '#!/bin/sh
printf "%%s\n" "$*" >> "%s/sudo.log"
' "$sandbox_root" > "$root/fake-bin/fake-sudo"
chmod +x "$root/fake-bin/fake-sudo"
HOME="$sandbox_root/home" SUDO="$root/fake-bin/fake-sudo" BLOOM_SANDBOX_HOME="$sandbox_root/agent"   BLOOM_WORKTREE="$sandbox_root/worktree" BLOOM_DATA_DIR="$sandbox_root/home/.bloom"   BLOOM_AGENT_SOURCE="$sandbox_root/home/.local/share/sprite-agents"   BLOOM_AGENT_TARGET="$sandbox_root/agents" BLOOM_SHARED_DIR="$sandbox_root/shared"   BLOOM_CREDENTIAL_SHIELD_SOURCE="$sandbox_root/credential-shield.so" BLOOM_CREDENTIAL_SHIELD_LIBRARY="$sandbox_root/installed-shield.so"   bash "$provision_script" >"$sandbox_root/out.log" 2>&1 || print -r -- "provision exited $?" >> "$sandbox_root/out.log"
sudo_log="$(<"$sandbox_root/sudo.log")"
check "the sandbox user is made with no sudo group" "yes" "$([[ "$sudo_log" == *"useradd --create-home --home-dir $sandbox_root/agent --shell /bin/bash --groups bloom-work bloom-agent"* ]] && echo yes || echo no)"
check "the shared group is made" "yes" "$([[ "$sudo_log" == *"groupadd bloom-work"* ]] && echo yes || echo no)"
provision_out="$(<"$sandbox_root/out.log")"
check "sudo is granted to the Runner's user and to nobody else" "yes" "$([[ "$provision_out" == *"granting: $(id -un) ALL=(ALL) NOPASSWD:SETENV: ALL"* && "$provision_out" != *"bloom-agent ALL="* ]] && echo yes || echo no)"
check "the sudoers file is checked before it is installed" "yes" "$([[ "$sudo_log" == *"visudo -cqf"* && "$sudo_log" == *"install -o root -g root -m 0440"* ]] && echo yes || echo no)"
check "the CLIs are copied where anybody can run them" "yes" "$([[ "$sudo_log" == *"chmod -R a+rX $sandbox_root/agents/claude"* ]] && echo yes || echo no)"
check "the Runner's home becomes traversable, and only the one it was given" "yes" "$([[ "$sudo_log" == *"chmod 0751 $sandbox_root/home"* && "$sudo_log" != *"chmod 0751 $HOME "* ]] && echo yes || echo no)"
check "the Runner's data directory stays private" "yes" "$([[ "$sudo_log" == *"chmod 0700 $sandbox_root/home/.bloom"* ]] && echo yes || echo no)"
check "the directory both users read is made setgid" "yes" "$([[ "$sudo_log" == *"chmod 2775 $sandbox_root/shared"* ]] && echo yes || echo no)"
check "v2 control paths are owned by the Runner and not group-writable" "yes" \
  "$([[ "$sudo_log" == *"chown $(id -un):bloom-work /var/lib/bloom/person-bound-shared"* && "$sudo_log" == *"chmod 0750 /var/lib/bloom/person-bound-shared"* ]] && echo yes || echo no)"
check "v2 network configuration is empty, root-owned and read-only" "yes" \
  "$([[ "$sudo_log" == *"chown root:root /var/lib/bloom/person-bound-config"* && "$sudo_log" == *"chmod 0555 /var/lib/bloom/person-bound-config"* ]] && echo yes || echo no)"
check "v2 execution provenance is root-only" "yes" \
  "$([[ "$sudo_log" == *"chown root:root /var/lib/bloom/person-bound-provenance"* && "$sudo_log" == *"chmod 0700 /var/lib/bloom/person-bound-provenance"* ]] && echo yes || echo no)"
check "the gh credential shield is installed root-owned and read-only" "yes" \
  "$([[ "$sudo_log" == *"install -o root -g root -m 0555 $sandbox_root/credential-shield.so $sandbox_root/installed-shield.so"* ]] && echo yes || echo no)"
check "the worktree is shared with the group" "yes" "$([[ "$sudo_log" == *"chgrp -R bloom-work $sandbox_root/worktree"* ]] && echo yes || echo no)"
check "running it twice asks for nothing twice" "" "$(HOME="$sandbox_root/home" SUDO=/usr/bin/true BLOOM_SANDBOX_HOME="$sandbox_root/agent" BLOOM_WORKTREE="$sandbox_root/worktree" BLOOM_DATA_DIR="$sandbox_root/home/.bloom" BLOOM_AGENT_SOURCE="$sandbox_root/home/.local/share/sprite-agents" BLOOM_AGENT_TARGET="$sandbox_root/agents" BLOOM_SHARED_DIR="$sandbox_root/shared" bash "$provision_script" >/dev/null 2>&1; echo -n "")"

if (( ${#failures} )); then
  print -r -- "runner-start probe failed:"
  for failure in $failures; do print -r -- "  $failure"; done
  exit 1
fi
print -r -- "runner-start probe passed"

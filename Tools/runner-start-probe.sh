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
  BLOOM_PREFIX="$prefix" BLOOM_UPDATE_MARKER="$marker" "$prefix/current/bin/bloom-runner" "$@" 2>>"$root/stderr.log" || true
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

# An update to a release that never answers: the script moves the symlink and leaves the marker for
# the start wrapper, because the restart it asks for is what kills this script. The revert is the
# wrapper's, and the checks above already cover it.
run_bootstrap update 2.1.0 "$sum_210"
check "the update moved current to the new version" "$bootstrap_prefix/2.1.0" "$(readlink "$bootstrap_prefix/current")"
check "current is still a symlink, not a directory" "yes" "$([[ -L "$bootstrap_prefix/current" ]] && echo yes || echo no)"
check "nothing was left beside it" "no" "$([[ -e "$bootstrap_prefix/current.next" ]] && echo yes || echo no)"
check "the marker is left for the wrapper" "2.1.0" "$(sed -n 1p "$root/bootstrap-marker" 2>/dev/null || true)"
check "with the version to go back to" "$bootstrap_prefix/2.0.0" "$(sed -n 2p "$root/bootstrap-marker" 2>/dev/null || true)"

# And the wrapper, handed that marker, is what actually goes back.
BLOOM_PREFIX="$bootstrap_prefix" BLOOM_UPDATE_MARKER="$root/bootstrap-marker" "$bootstrap_prefix/current/bin/bloom-runner" serve 2>/dev/null || true
BLOOM_PREFIX="$bootstrap_prefix" BLOOM_UPDATE_MARKER="$root/bootstrap-marker" "$bootstrap_prefix/current/bin/bloom-runner" serve 2>/dev/null || true
check "the wrapper goes back to the release that worked" "$bootstrap_prefix/2.0.0" "$(readlink "$bootstrap_prefix/current")"

if (( ${#failures} )); then
  print -r -- "runner-start probe failed:"
  for failure in $failures; do print -r -- "  $failure"; done
  exit 1
fi
print -r -- "runner-start probe passed"

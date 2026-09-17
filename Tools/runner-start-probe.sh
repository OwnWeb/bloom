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

if (( ${#failures} )); then
  print -r -- "runner-start probe failed:"
  for failure in $failures; do print -r -- "  $failure"; done
  exit 1
fi
print -r -- "runner-start probe passed"

#!/bin/zsh
# Deletes the test machines that crashed runs left behind.
#
# Automated tests name every machine they create `bloomtest-<...>` and delete it in their own
# teardown. A run that is killed never gets to its teardown, and a machine nobody deletes bills for
# its storage for ever, so this finds `bloomtest-` machines older than a day and deletes them.
#
#   ./Tools/sweep-test-machines.sh             delete them
#   ./Tools/sweep-test-machines.sh --dry-run   only say which
#
# **It can only ever touch a test machine, and it checks that three times.** The list is asked for
# with the `bloomtest-` prefix, every name that comes back is matched again against the whole
# pattern here, and the organisation the Sprites CLI is signed in to has to be the development one,
# because production Cloud workspaces live in another organisation and are named `bloom-<ulid>`,
# which does not start with `bloomtest-` however the prefix is spelt. Development machines
# (`bloomdev-`) are left alone: a person made those and a person deletes them.
#
# Environment:
#   BLOOM_TEST_SPRITES_ORG  the organisation to sweep (default freek-van-der-herten)
#   BLOOM_TEST_MACHINE_AGE  seconds a machine must have existed before it goes (default 86400)

set -euo pipefail

organisation="${BLOOM_TEST_SPRITES_ORG:-freek-van-der-herten}"
minimum_age="${BLOOM_TEST_MACHINE_AGE:-86400}"
dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1

sprite="$(command -v sprite || true)"
[[ -z "$sprite" && -x "$HOME/.local/bin/sprite" ]] && sprite="$HOME/.local/bin/sprite"
if [[ -z "$sprite" ]]; then
  print -r -- "The Sprites CLI is not installed, so there is nothing to sweep with."
  exit 1
fi

# `sprite api` says which organisation it is calling on stderr. Anything other than the one named
# above stops the sweep before a single name is read.
api() {
  local output errors
  errors="$(mktemp)"
  output="$("$sprite" api -o "$organisation" "$@" 2>"$errors")" || { cat "$errors" >&2; rm -f "$errors"; return 1; }
  if ! grep -q "Calling API: $organisation\$" "$errors"; then
    print -r -- "The Sprites CLI is not calling the $organisation organisation. Refusing to sweep." >&2
    rm -f "$errors"
    return 1
  fi
  rm -f "$errors"
  print -r -- "$output"
}

now="$(date -u +%s)"
token=""
swept=0
while true; do
  query="/v1/sprites?prefix=bloomtest-&max_results=100"
  [[ -n "$token" ]] && query="$query&continuation_token=$token"
  page="$(api "$query")"
  names=("${(@f)$(print -r -- "$page" | python3 -c 'import json,sys; [print(s["name"]) for s in json.load(sys.stdin).get("sprites", [])]')}")
  for name in $names; do
    [[ -z "$name" ]] && continue
    if [[ ! "$name" =~ '^bloomtest-[a-z0-9][a-z0-9-]*$' ]]; then
      print -r -- "skipping $name: not a test machine name"
      continue
    fi
    created="$(api "/v1/sprites/$name" | python3 -c 'import json,sys,datetime; t=json.load(sys.stdin).get("created_at"); print(int(datetime.datetime.fromisoformat(t.replace("Z","+00:00")).timestamp()) if t else "")')"
    if [[ -z "$created" ]] || (( now - created < minimum_age )); then
      continue
    fi
    if (( dry_run )); then
      print -r -- "would delete $name"
    else
      api "/v1/sprites/$name" -- -X DELETE >/dev/null
      print -r -- "deleted $name"
    fi
    swept=$((swept + 1))
  done
  token="$(print -r -- "$page" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("next_continuation_token") or "")')"
  [[ -z "$token" ]] && break
done

print -r -- "$swept test machine(s) older than $minimum_age seconds in $organisation."

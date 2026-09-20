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
#   BLOOM_TEST_SPRITES_ORG  the development organisation to sweep, required; its name stays out of
#                           this public repository
#   BLOOM_TEST_MACHINE_AGE  seconds a machine must have existed before it goes (default 86400)

set -euo pipefail

organisation="${BLOOM_TEST_SPRITES_ORG:?Set BLOOM_TEST_SPRITES_ORG to the development Sprites organisation.}"
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
left=0
# A machine the provider will not delete would otherwise be found again on every pass.
passes=0
while true; do
  query="/v1/sprites?prefix=bloomtest-&max_results=100"
  [[ -n "$token" ]] && query="$query&continuation_token=$token"
  before_page=$swept
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
      # Deleted is a thing to confirm, not a thing to be told. A machine the provider reported as
      # destroyed has come back into the list, and a Sprite holding a clone of somebody's
      # repository that we believe is gone is both a bill and a copy of their code.
      confirmed=0
      for attempt in 1 2 3; do
        api "/v1/sprites/$name" -- -X DELETE >/dev/null || true
        sleep 2
        if ! api "/v1/sprites?prefix=$name&max_results=10" |
            python3 -c 'import json,sys; print("\n".join(s["name"] for s in json.load(sys.stdin).get("sprites", [])))' |
            grep -qx "$name"; then
          confirmed=1
          break
        fi
      done
      if (( confirmed )); then
        print -r -- "deleted $name"
      else
        print -r -- "COULD NOT DELETE $name: it is still in the list after three attempts"
        left=$((left + 1))
      fi
    fi
    swept=$((swept + 1))
  done
  # The next page is asked for from the token this page came with, but this page's deletions have
  # already moved the list under it. Rather than trusting a token taken before the deletes, the
  # sweep starts again from the beginning when it deleted anything, and stops when a whole pass
  # deletes nothing.
  passes=$((passes + 1))
  if (( swept > before_page && ! dry_run && passes < 20 )); then
    token=""
    continue
  fi
  token="$(print -r -- "$page" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("next_continuation_token") or "")')"
  [[ -z "$token" ]] && break
done

print -r -- "$swept test machine(s) older than $minimum_age seconds in $organisation."
if (( left )); then
  print -r -- "$left of them are still there. Look at them by hand: the provider said they were deleted."
  exit 1
fi

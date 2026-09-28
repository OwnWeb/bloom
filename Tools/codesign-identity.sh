#!/bin/zsh
# Which identity a locally installed build is signed with. Sourced, not run.
#
# **This exists because of the keychain, not because of Gatekeeper.** macOS records
# "Always Allow" against an application's designated requirement, and an ad-hoc
# signature's requirement is its cdhash, which is a different number for every
# build. So every install was, as far as the keychain was concerned, a different
# application asking for somebody else's secret: the owner was asked for his
# password again on each one, pressed Always Allow, and was asked again by the next
# build an hour later. Worse than the dialog, refusing it reads as a token that
# cannot be read, so each install signed him out of his Bloom account as well.
#
# A Developer ID certificate's requirement is its team identifier and the bundle id,
# neither of which moves between builds, so the ACL granted once keeps matching. Any
# stable certificate would do; this one is already on the machine that releases
# Bloom, so it is the one to reach for rather than a second one to create and
# explain. A machine without one falls back to ad-hoc and says so, because an
# unsigned build that runs is better than a build script that refuses to finish.
#
# The environment still wins, and the pre-rename spelling is still read, so a shell
# profile or a CI job that names an identity keeps getting that one.
bloom_codesign_identity() {
  if [[ -n "${BLOOM_CODESIGN_IDENTITY:-}" ]]; then
    print -r -- "$BLOOM_CODESIGN_IDENTITY"
    return
  fi
  if [[ -n "${BATON_CODESIGN_IDENTITY:-}" ]]; then
    print -r -- "$BATON_CODESIGN_IDENTITY"
    return
  fi
  local found
  found="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
  if [[ -n "$found" ]]; then
    print -r -- "$found"
    return
  fi
  print -r -- "-"
}

# Says what the fallback costs, once, where the build says what it did.
#
# **A locked login keychain looks exactly like having no certificate.** `security
# find-identity` reads the keychain, so a Mac whose keychain has not been unlocked
# since boot answers with nothing and this falls silently back to ad-hoc, which is
# the one case where the fallback is wrong rather than merely unfortunate: the
# certificate is right there. That is why the note names it.
bloom_codesign_note() {
  [[ "$1" == "-" ]] || return 0
  print -r -- "==> ad-hoc signed: no Developer ID certificate was found on this Mac."
  print -r -- "    Every build is then a different application to the keychain, so the"
  print -r -- "    Bloom account token has to be allowed again after each install."
  print -r -- "    If there is a certificate, the login keychain may be locked: unlock it"
  print -r -- "    and build again for a signature the keychain will go on trusting."
}

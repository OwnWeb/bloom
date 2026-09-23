#!/usr/bin/env bash
# Makes the machine's sandbox user, the one that agents, terminals, scripts and services run as.
#
# Called by bootstrap-machine.sh on install and on update, and safe to run twice: every step checks
# before it acts. It is the machine half of H1 in the security review of 19 September 2026.
#
# What it makes, and why each part is needed:
#
# 1. A group, `bloom-work`, for the worktree, and a user, `bloom-agent`, with **no sudo**. The
#    Runner's own user keeps sudo, because updates need it.
# 2. A sudoers line letting the Runner's user become anybody without a password, and keep the
#    environment. That is how it starts a sandboxed process: `sudo -E unshare ... setpriv --reuid`.
#    The sandbox user is given nothing.
# 3. Links in /usr/local/bin to the agent CLIs where the image already installs them, so PATH
#    finds them. They used to be copied, every one of them with `cp -rL`, because the Runner's
#    home was 0750 and the sandbox user could not reach them; item 5 makes that home 0751, so the
#    copy only cost time at every install, hundreds of megabytes of it, for five agents of which
#    two are ever launched from here. The sandbox user can run them in place and cannot change
#    them, since they belong to the Runner's user.
# 4. The sandbox user's own HOME, because a CLI writes its state there and cannot read the
#    Runner's home, with only the permission settings from the image's Claude settings. Not the
#    image's hooks, skills or instructions: those are written for a person using the Sprite.
# 5. The Runner's home made traversable (0751) and the worktree group-shared with setgid, so both
#    users can work in the same checkout. **The Runner's data directory stays 0700**: the workspace
#    secret and the database are in it and the sandbox user must never read them.
#
# Environment:
#   BLOOM_SANDBOX_USER   the user to make (default bloom-agent)
#   BLOOM_SANDBOX_GROUP  the shared group (default bloom-work)
#   BLOOM_SANDBOX_HOME   that user's home (default /home/<user>)
#   BLOOM_SHARED_DIR     what both users read (default /var/lib/bloom/shared)
#   BLOOM_PERSON_BOUND_SHARED_DIR  Runner-owned v2 sockets and wrappers
#   BLOOM_PERSON_BOUND_CONFIG_DIR  root-owned empty network configuration
#   BLOOM_PERSON_BOUND_HOME_ROOT  ephemeral v2 homes (default /var/lib/bloom/person-bound)
#   BLOOM_WORKTREE       the checkout to share (default $HOME/workspace)
#   BLOOM_DATA_DIR       the Runner's own directory, left private (default $HOME/.bloom)
#   BLOOM_AGENT_SOURCE   where the image keeps the CLIs (default $HOME/.local/share/sprite-agents)
#   BLOOM_AGENT_LINKS    where the links go (default /usr/local/bin)
#   SUDO                 how to become root (default sudo), so a test can watch instead

set -euo pipefail

user="${BLOOM_SANDBOX_USER:-bloom-agent}"
group="${BLOOM_SANDBOX_GROUP:-bloom-work}"
worktree="${BLOOM_WORKTREE:-$HOME/workspace}"
data="${BLOOM_DATA_DIR:-$HOME/.bloom}"
source_dir="${BLOOM_AGENT_SOURCE:-$HOME/.local/share/sprite-agents}"
link_dir="${BLOOM_AGENT_LINKS:-/usr/local/bin}"
sudo_cmd="${SUDO:-sudo}"
runner="$(id -un)"
# **$HOME, not the passwd entry.** Looked up by name this reached the home of whoever ran it, which
# in a test was the author's own, and this script changes permissions on what it is given.
home="${HOME:?HOME has to be set}"

say() { echo "provision-sandbox: $*"; }

# 1. The group and the user.
getent group "$group" >/dev/null || $sudo_cmd groupadd "$group"
if getent passwd "$user" >/dev/null; then
  say "$user exists"
else
  $sudo_cmd useradd --create-home --home-dir "${BLOOM_SANDBOX_HOME:-/home/$user}" --shell /bin/bash --groups "$group" "$user"
fi
id -nG "$runner" | tr ' ' '\n' | grep -qx "$group" || $sudo_cmd usermod --append --groups "$group" "$runner"

# 2. The one sudoers line. Written to a temporary file and checked with visudo before it is put in
# place, because a broken file in /etc/sudoers.d takes sudo away from every user at once.
sudoers="/etc/sudoers.d/bloom-sandbox"
line="$runner ALL=(ALL) NOPASSWD:SETENV: ALL"
if [[ "$($sudo_cmd cat "$sudoers" 2>/dev/null || true)" != "$line" ]]; then
  temporary="$(mktemp)"
  printf '%s\n' "$line" > "$temporary"
  say "granting: $line"
  $sudo_cmd visudo -cqf "$temporary"
  $sudo_cmd install -o root -g root -m 0440 "$temporary" "$sudoers"
  rm -f "$temporary"
fi

# 3. The names the CLIs are launched by, pointing at where the image already keeps them. A link
# only where nothing of that name is there already.
if [[ -d "$source_dir" ]]; then
  $sudo_cmd mkdir -p "$link_dir"
  for pair in "claude:claude/claude" "codex:codex/codex-x86_64-unknown-linux-musl"; do
    name="${pair%%:*}"
    path="$source_dir/${pair#*:}"
    [[ -e "$path" ]] || continue
    # The copy used to be made readable and runnable by everybody; the image's own install is not
    # promised to be, so the one directory that is linked to is made so instead, in place.
    $sudo_cmd chmod -R a+rX "$(dirname "$path")"
    if [[ ! -e "$link_dir/$name" ]]; then
      $sudo_cmd ln -s "$path" "$link_dir/$name"
    fi
  done
fi

# 4. The sandbox user's home, and the one thing it takes from the image's Claude home: the
# permission settings in settings.json.
#
# **The whole of `$HOME/.claude` used to be copied**, with `cp -rL`, and the image's hooks and
# skills came with it. They are written for a person working on a Sprite directly, and while the
# agent had a throwaway home per launch nothing read them. From Runner test.53 the agent keeps this
# home, so they took effect: the `sprite-api-gateway` skill told Bloom's agent that the Sprites API
# gateway "is the only supported way to access external APIs from a Sprite", and the agent went
# looking there for a GitHub connection instead of using Bloom's credentialled git and gh.
#
# So settings.json is written from a list of the keys Bloom wants, and what the image adds for its
# own use is removed on every run, which is also what cleans a machine the old copy provisioned.
# What Claude writes for itself (projects/, shell-snapshots/, sessions, credentials) is never
# named, so it is never touched.
#
# Named rather than looked up, so this is the same path before and after the user is made, and a
# test can point it somewhere harmless.
sandbox_home="${BLOOM_SANDBOX_HOME:-/home/$user}"
agent_claude="$sandbox_home/.claude"
$sudo_cmd install -d -o "$user" -g "$user" -m 0700 "$agent_claude"
$sudo_cmd rm -rf "$agent_claude/skills" "$agent_claude/hooks" "$agent_claude/agents" \
  "$agent_claude/commands" "$agent_claude/plugins" "$agent_claude/output-styles" "$agent_claude/CLAUDE.md"
# python3 because the machine already has it (bootstrap-machine.sh leans on it for its rename) and
# jq is not promised. Read as the Runner, whose file it is, and installed as the agent's. A file
# that is missing or does not parse gives `{}`, so a machine still loses the hooks it had.
agent_settings="$(mktemp)"
if command -v python3 >/dev/null; then
  python3 - "$home/.claude/settings.json" > "$agent_settings" <<'PY'
import json, sys
keep = ("permissions", "defaultMode", "skipDangerousModePermissionPrompt")
try:
    with open(sys.argv[1]) as handle:
        image = json.load(handle)
except (OSError, ValueError):
    image = {}
if not isinstance(image, dict):
    image = {}
json.dump({key: image[key] for key in keep if key in image}, sys.stdout, indent=2)
print()
PY
else
  say "python3 is missing, so the agent gets no permission settings from the image"
  printf '{}\n' > "$agent_settings"
fi
$sudo_cmd install -o "$user" -g "$user" -m 0600 "$agent_settings" "$agent_claude/settings.json"
rm -f "$agent_settings"

# 5. The one directory both users read, for the tmux configuration and anything like it. The
# Runner's own data directory cannot be it: the workspace secret and the database are in there.
shared="${BLOOM_SHARED_DIR:-/var/lib/bloom/shared}"
$sudo_cmd mkdir -p "$shared"
$sudo_cmd chgrp "$group" "$shared"
$sudo_cmd chmod 2775 "$shared"

# V2 processes may connect to these sockets and execute these wrappers, but cannot unlink or
# replace either. The legacy shared directory remains writable for its existing uses.
person_bound_shared="${BLOOM_PERSON_BOUND_SHARED_DIR:-/var/lib/bloom/person-bound-shared}"
$sudo_cmd mkdir -p "$person_bound_shared"
$sudo_cmd chown "$runner:$group" "$person_bound_shared"
$sudo_cmd chmod 0750 "$person_bound_shared"

# Network Git and gh run with this as their complete configuration home. Root owns it and nobody
# may add a proxy, CA, URL rewrite, helper or alternate Unix socket after the runtime proof.
person_bound_empty_config="${BLOOM_PERSON_BOUND_CONFIG_DIR:-/var/lib/bloom/person-bound-config}"
$sudo_cmd mkdir -p "$person_bound_empty_config"
$sudo_cmd chown root:root "$person_bound_empty_config"
$sudo_cmd chmod 0555 "$person_bound_empty_config"

# Numeric v2 users own only their one child of this root. The parent is traversable but not
# writable, and each child is created mode 0700 by bloom-runner's privileged launch helper.
person_bound_home_root="${BLOOM_PERSON_BOUND_HOME_ROOT:-/var/lib/bloom/person-bound}"
$sudo_cmd mkdir -p "$person_bound_home_root"
$sudo_cmd chown root:root "$person_bound_home_root"
$sudo_cmd chmod 0711 "$person_bound_home_root"

# Only the privileged launch supervisor and command attestor may write or read execution history.
# A script cannot erase its provenance by execing a system binary before it reaches a wrapper.
person_bound_provenance="${BLOOM_PERSON_BOUND_PROVENANCE_ROOT:-/var/lib/bloom/person-bound-provenance}"
$sudo_cmd mkdir -p "$person_bound_provenance"
$sudo_cmd chown root:root "$person_bound_provenance"
$sudo_cmd chmod 0700 "$person_bound_provenance"

# gh only accepts a token through its environment. This root-owned preload closes same-uid /proc
# inspection before gh's main function can observe the token. Packaged Runners carry it in lib/.
credential_shield="${BLOOM_CREDENTIAL_SHIELD_LIBRARY:-/usr/local/lib/bloom-credential-shield.so}"
credential_shield_source="${BLOOM_CREDENTIAL_SHIELD_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/bloom-credential-shield.so}"
if [[ -f "$credential_shield_source" && "$credential_shield_source" != "$credential_shield" ]]; then
  $sudo_cmd install -o root -g root -m 0555 "$credential_shield_source" "$credential_shield"
elif [[ -f "$credential_shield" ]]; then
  $sudo_cmd chown root:root "$credential_shield"
  $sudo_cmd chmod 0555 "$credential_shield"
else
  say "credential shield is unavailable; Bloom Runner will refuse to start"
fi

# 6. Both users in one checkout, and the Runner's own directory still private.
$sudo_cmd chmod 0751 "$home"

# Made here when it is missing, because nothing else can any more. The Runner's home is 0751 so
# that `bloom-agent` may pass through it and not write in it, and since person-bound credentials
# became the only path, the clone runs as `bloom-agent` rather than as the Runner. So git was
# asked to create `$HOME/workspace` inside a directory it is deliberately not allowed to write to,
# and every clone died with "could not create work tree dir: Permission denied". Owned by the
# Runner, shared with the group, setgid so whatever either of them writes stays shared.
if [[ ! -d "$worktree" ]]; then
  $sudo_cmd install -d -o "$(id -un)" -g "$group" -m 2770 "$worktree"
fi

# Both of them run git in this checkout, and only one of them owns it. Git refuses a repository
# owned by somebody else with "detected dubious ownership", which is right on a laptop and wrong
# here: this directory is shared between two accounts on purpose, both of them ours. Named
# explicitly rather than by a wildcard, and system wide because whichever of them runs git needs it.
if command -v git >/dev/null; then
  $sudo_cmd git config --system --replace-all safe.directory "$worktree"
fi

if [[ -d "$worktree" ]]; then
  $sudo_cmd chgrp -R "$group" "$worktree"
  $sudo_cmd chmod -R g+rwX "$worktree"
  # setgid, so a file either of them makes stays in the shared group.
  find "$worktree" -type d -print0 2>/dev/null | xargs -0 -r "$sudo_cmd" chmod g+s
fi
if [[ -d "$data" ]]; then
  $sudo_cmd chmod 0700 "$data"
fi

say "ready: $user in $group, CLIs linked into $link_dir"

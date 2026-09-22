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
# 3. A copy of the agent CLIs under /usr/local/lib/bloom-agents, root-owned and world-readable,
#    because the image installs them under the Runner user's home, which is 0750, and a copy is the
#    only way the sandbox user can run them. Symlinks in /usr/local/bin so PATH finds them.
# 4. The sandbox user's own HOME, with the image's Claude settings copied into it, because a CLI
#    writes its state there and cannot read the Runner's home.
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
#   BLOOM_AGENT_TARGET   where the copy goes (default /usr/local/lib/bloom-agents)
#   SUDO                 how to become root (default sudo), so a test can watch instead

set -euo pipefail

user="${BLOOM_SANDBOX_USER:-bloom-agent}"
group="${BLOOM_SANDBOX_GROUP:-bloom-work}"
worktree="${BLOOM_WORKTREE:-$HOME/workspace}"
data="${BLOOM_DATA_DIR:-$HOME/.bloom}"
source_dir="${BLOOM_AGENT_SOURCE:-$HOME/.local/share/sprite-agents}"
target_dir="${BLOOM_AGENT_TARGET:-/usr/local/lib/bloom-agents}"
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

# 3. The CLIs, where a user who cannot read the Runner's home can run them.
if [[ -d "$source_dir" ]]; then
  $sudo_cmd mkdir -p "$target_dir"
  for agent in "$source_dir"/*; do
    [[ -d "$agent" ]] || continue
    name="$(basename "$agent")"
    [[ -e "$target_dir/$name" ]] && continue
    $sudo_cmd cp -rL "$agent" "$target_dir/$name"
    $sudo_cmd chown -R root:root "$target_dir/$name"
    $sudo_cmd chmod -R a+rX "$target_dir/$name"
  done
  # The names the CLIs are launched by. A link only where nothing of that name is there already.
  for pair in "claude:claude/claude" "codex:codex/codex-x86_64-unknown-linux-musl"; do
    name="${pair%%:*}"
    path="$target_dir/${pair#*:}"
    if [[ -x "$path" && ! -e "/usr/local/bin/$name" ]]; then
      $sudo_cmd ln -s "$path" "/usr/local/bin/$name"
    fi
  done
fi

# 4. The sandbox user's home, with the image's Claude settings, which carry the Sprite hooks and
# skills and the permission mode a machine runs in.
# Named rather than looked up, so this is the same path before and after the user is made, and a
# test can point it somewhere harmless.
sandbox_home="${BLOOM_SANDBOX_HOME:-/home/$user}"
if [[ -d "$home/.claude" && ! -e "$sandbox_home/.claude" ]]; then
  $sudo_cmd cp -rL "$home/.claude" "$sandbox_home/.claude"
  $sudo_cmd chown -R "$user:$user" "$sandbox_home/.claude"
fi

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

if [[ -d "$worktree" ]]; then
  $sudo_cmd chgrp -R "$group" "$worktree"
  $sudo_cmd chmod -R g+rwX "$worktree"
  # setgid, so a file either of them makes stays in the shared group.
  find "$worktree" -type d -print0 2>/dev/null | xargs -0 -r "$sudo_cmd" chmod g+s
fi
if [[ -d "$data" ]]; then
  $sudo_cmd chmod 0700 "$data"
fi

say "ready: $user in $group, CLIs in $target_dir"

# Cloud workspaces on Sprites

Status: design, agreed with the runbloom.app side (its pull request #23), September 2026. Nothing here is built yet. This document is what the next pull
request builds, and the order it builds it in. The control server half lives in the runbloom.app
repository and is designed there; the contract between the two is written down here as well,
because both sides have to read the same one.

A cloud workspace is a Bloom workspace whose worktree, agents, terminals and transcript live on a
Fly.io Sprite instead of this Mac. One Sprite per workspace, and the Sprite is the isolation
boundary. Several people can work in the same one.

**Nobody using Bloom sees Fly or a Sprite.** runbloom.app runs every cloud workspace in one Fly
organisation with one token, for every team; nobody connects a Fly account. In the app (sidebar,
create window, menus, errors), on runbloom.app and in any message a person can read, it is a
**Cloud workspace**, plural **Cloud workspaces**, and never a remote workspace, a Fly machine or a
Sprite. Type names in code stay neutral (`Remote…`, `Machine…`), because they are not read by
anyone using the app. "Sprite" appears in this document, in the provider implementation and in
logs, and nowhere else. The provider stays behind the interface described under "Where the code
goes", so a second provider changes no user-facing word.

What this replaces: the self-provisioned SSH server of pull request #163 (install scripts, SSH
wizard, rootless Docker, swap, storage cleanup, server updates) is dropped entirely. #163 stays open
as a quarry; "Two pull requests, and what comes from #163" says what is taken from it and what is not.

## Measured facts this design rests on

These come from spikes on real Sprites in September 2026 and are the reason for most decisions
below. Change a fact and look again at the decision that cites it.

- Create takes 0.4 to 0.7 s. Ubuntu 26.04 x86_64, 8 vCPU, 8 to 16 GB memory scaled
  automatically, 99 GB disk, passwordless sudo, no systemd (tini is PID 1). `claude`, `codex`,
  `gh`, `git`, `tmux`, `node`, `python` and `go` are preinstalled. The #163 Linux package already
  targets this OS.
- About 30 s after activity stops a Sprite pauses: billing stops and processes freeze. Warm wake
  measured 0.87 s. After about 10 minutes it goes cold; the documentation says memory is dropped,
  and a measured cold wake took 0.4 s with a process still alive. **Every open TCP connection
  breaks on a pause.**
- A Sprite Service restarts on cold wake. Background processes do not keep a Sprite awake; open
  connections through a service do. A task on the Tasks API (`/.sprite/api.sock`) holds it awake
  for up to an hour with a heartbeat, verified for 100 s with nothing connected. **A turn that does
  not hold a task has its model call broken by a pause.**
- The Sprite URL routes to one HTTP port. It is private (Fly organisation login or an organisation
  token) or public. `sprite proxy` streamed SSE for 190 s.
- A Sprite cannot be created from another Sprite's checkpoint. Checkpoints restore only into the
  Sprite they came from, so every workspace sets up from nothing.
- Sprites never delete themselves and storage bills until they are deleted.
- A service another service depends on cannot be deleted, and creating a service under an
  existing name silently keeps the old definition.
- Price: $0.07 per CPU hour used, $0.04375 per GB hour of memory used, $0.50 per GB month of hot
  storage while running, $0.02 per GB month of storage always.
- Docker on a Sprite is fragile: no memory cgroup controller, `docker exec` into a non-root
  container needs `init: true`, rootless Docker fails, BuildKit intermittently fails reading
  `/proc/meminfo`. spatie/there-there.app set up natively (Postgres with pgvector, Redis, Horizon,
  Reverb, Vite, Caddy) served its homepage 149 s after create; with Docker it took about 7.5
  minutes. Apt was 79 s of the 149, seeding 42 s, upload 17 s. It needed `APP_URL` set to the
  Sprite URL and `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` in the process environment rather than
  `.env`.

## The shape

```mermaid
flowchart LR
    Mac[Mac app] -- OAuth, list, tokens --> Control[runbloom.app]
    iOS[iOS app, later] -- OAuth, list, tokens --> Control
    Mac -- RPC, events, terminal, preview --> Sprite
    iOS -- RPC, events, terminal, preview --> Sprite
    subgraph Sprite[One Sprite per workspace]
        Front[Caddy on the URL port] --> Server[Bloom Runner]
        Front --> App[the project's app]
        Server --> Agents[claude, codex]
        Server --> Services[project services]
    end
    Server -- summary, credentials, git tokens --> Control
    Control -- create, exec, delete --> Fly[Sprites API]
```

**runbloom.app** owns accounts, teams and membership, authorisation, the workspace registry with a
summary per workspace, Sprite lifecycle (create, bootstrap, update, delete, orphan sweep),
provider credentials, agent and environment secrets, the GitHub App, and push notifications.
It never carries transcript, terminal or preview bytes: it is a single core Forge box running
PHP-FPM, and a long-lived stream is the one thing it is bad at.

**Bloom Runner** runs inside the Sprite and owns exactly one workspace: its checkout, agent
processes, prompt queue, transcript, terminals, project services, setup and the Sprite's awake
state. It is the #163 runtime cut down, with an HTTP front instead of a Unix socket behind a Go
gateway.

**Clients** sign in to runbloom.app, list workspaces from it without waking anything, and talk to
a Sprite directly with a short-lived token runbloom.app issued for that one workspace.

Clients stream from the Sprite rather than through runbloom.app. The alternative that keeps Sprite
URLs private is a relay holding a Fly organisation token, and that relay could not be PHP, so it
would be a third service to deploy and operate for one benefit (a private URL) that Bloom Runner's
own token check provides as well. If that changes, the relay slots in front of the same endpoints
without a protocol change.

## Identity and tokens

### Signing in

The Mac signs in to runbloom.app with OAuth 2 authorisation code and PKCE against Laravel Passport:
a public client with no secret, and refresh tokens in the Keychain. The redirect is
`bloom://oauth/callback`, and `bloomdev://oauth/callback` for Bloom Dev, which has its own scheme.
There is no loopback redirect, because Passport compares redirect URIs exactly and a loopback
redirect carries a different port every time. `BloomAuthentication` from #163 wraps AppAuth, whose
Mac user agent is `ASWebAuthenticationSession`, which takes a custom scheme callback; #163 used it
with loopback, so the Mac path changes to the custom scheme. It reads its endpoints from a
`/.well-known/bloom-auth` document, which runbloom.app can serve, or they can be configured in the
app. runbloom.app's own API uses those access tokens.

### Workspace tokens

A client exchanges its runbloom.app access token for a workspace token:
`POST /api/v1/cloud-workspaces/{id}/session-token`. runbloom.app refuses it with `{"code":
"machine_not_ready", "message", "retry_after"}` (HTTP 409) until Bloom Runner on that machine has
posted its first summary, so a client never connects to a URL with nothing behind it. From that
first summary on, which Bloom Runner posts before setup starts, a token is issued, so the setup
output can be watched live. A sleeping machine is ready: the token is what the client then uses to
wake it. The reply is an EdDSA JWT, five minutes long:

| Claim | Value |
| --- | --- |
| `iss` | `https://runbloom.app` |
| `aud` | `bloom-workspace:<workspace id>` |
| `sub` | user id |
| `name` | display name, for presence |
| `team` | team id |
| `abilities` | subset of `view`, `prompt`, `terminal`, `files`, `preview`, `share` |
| `iat`, `exp`, `jti` | `exp` is `iat` + 300 |

The header carries `kid`. Abilities rather than a role, so a read-only viewer later is a
different set of strings and not a format change.

Bloom Runner verifies offline against runbloom.app's JWKS. The issuer and the JWKS URL are written
into the Sprite at bootstrap, never read from the token. The key set is cached and refetched on an
unknown `kid`, at most once a minute. Verification is Ed25519 through swift-crypto, which the Linux
build already depends on; no JWT library.

Every request and every stream open checks a token. An open stream remembers its token's `exp`, and
the client sends a fresh token on it at least 60 s before (a `reauth` frame on a WebSocket, `POST
/_bloom/v1/streams/{id}/token` for an event stream). A stream whose token expires is closed with
`token_expired`. Removing someone from a team takes effect within five minutes by expiry, and at
once when runbloom.app calls `POST /_bloom/v1/control/revoke`, which closes that user's streams.

runbloom.app stores only a hash of the workspace secret, so it cannot use that secret to call the
Sprite. It signs its own token instead, verified against the same pinned key set: `aud`
`bloom-workspace:<id>` for that one workspace, `sub` `control`, the `admin` ability that no user
token carries, and a 60 s lifetime. The Sprite remembers each `jti` until it expires and refuses a
replay. That covers every call from runbloom.app to a Sprite: revoke, update, pushing changed
environment.

### The workspace secret

Generated at create, stored hashed on runbloom.app, written to the Sprite at
`/etc/bloom/workspace.json` (mode 600) at bootstrap, and revoked on archive. It authorises the Sprite
towards runbloom.app: posting its own summary, fetching git tokens for its own repository, fetching
team and project environment, and starting a turn a user has already registered (below). **It also
reaches past its own workspace**, while a turn is running and the team's switches allow it: listing
the other workspaces that turn's person can open and minting a token to message one
(`RunbloomPeers`), creating a Cloud workspace (`RunbloomCloudWorkspaces`), and mailing a member
through `/addressed`.

An agent in the Sprite has passwordless sudo and can read that file, and it can read the
environment of its own process, so it can make every one of those calls itself. The agent
credential is visible to the agent in every design where the unmodified CLI runs, and within one
workspace that is accepted. Beyond it, what holds is the other end: a token minted for an agent
may only send a message on the receiving machine (see `RemoteCaller.agentMayRun`), runbloom.app
limits minting per origin, and each switch is off by default. What narrows the damage otherwise is
short lifetimes and (later, per project) the Sprite's DNS egress allowlist. Running the agent,
terminals and scripts as a second Unix user without sudo, so that none of them can read the secret,
is being designed after the security review of 19 September 2026.

### The sandbox user

**Everything the repository or an agent controls runs as `bloom-agent`, which has no sudo**: the
agents, the tmux server behind the terminals, the setup and resume scripts, the run scripts and the
services. The Runner keeps its own user, which has sudo, because updates need it. H1 in the security
review of 19 September 2026 is why, and `Tools/provision-sandbox.sh` is what makes it, on install and
on every update, idempotently.

**A second user alone isolates nothing on a Sprite, which is the part worth knowing.** `/.sprite/api.sock`
is world-writable on a read-only mount, so any local user can create a service that runs as the
Runner's user; measured on 19 September 2026. So a sandboxed command is
`sudo -E unshare --mount --propagation private -- sh -c 'mount --bind /dev/null /.sprite/api.sock &&
exec setpriv --reuid=bloom-agent …'`. The namespace is private, so the mask is that process tree's
alone and the Runner keeps its own access; inside it, `umount` needs superuser and `unshare` is
refused. The environment is passed with `-E` rather than in arguments, because a turn's keys travel
in it and `ps` shows arguments to everybody. See `MachineSandbox`.

**What the two users share, and what they do not.** The worktree is group `bloom-work`, setgid, so
both work in one checkout; `/var/lib/bloom/shared` holds what the Runner writes for the sandbox user,
which is the tmux configuration and the credential socket. The Runner's data directory stays 0700:
the database, and `~/.bloom/local-secret`, are not the sandbox user's to read. The agent CLIs are
copied to `/usr/local/lib/bloom-agents`, root-owned and world-readable, because the image installs
them under a 0750 home.

**Root for the first setup of a pristine checkout, and nothing else.** A workspace cut from the base
branch runs its first setup as the Runner's user, so a project can install packages, add a PPA or
build an extension. Every later run, and any first setup on a pull request's code, runs as
`bloom-agent`: what a script runs is the worktree's code, so an agent that edits `package.json` would
otherwise get root out of the next `npm install`. Whether a checkout is pristine is read from git,
never claimed. A script refused root gets a sentence naming the command and the code
`setup_needs_fresh_machine`, which is also `setup.failure_code` on the wire.

**A machine built before this runs as it always did.** `MachineSandbox.available()` answers nil where
the user or `unshare` or `setpriv` is missing, and everything runs as the Runner's user, which is
what the Runner says at start.

## Agent credentials

Anthropic's Claude Code terms settle this. A product that hosts Claude Code needs the Commercial
Terms; each end user authenticates with their own API key or subscription; usage is not paid for or
resold on their behalf; and "developers may not collect, store, or intermediate Claude.ai
credentials or session tokens", with sign-in completing through Anthropic's own flow. The same page
permits a customer to configure its own API key for its own authorised users, billed to the key
owner, and permits an end user to sign in to the unmodified binary with their own subscription on a
hosted platform. OpenAI recommends API keys for automation and treats Codex's `auth.json` as a
password.

So:

- **Phase 1 is API keys only.** A team key (Anthropic Console, OpenAI) is the default, and a user
  can add a personal key that overrides it for their own turns, stored encrypted on runbloom.app.
  **A personal key is used only in a workspace that is not shared.** Everyone in a workspace has a
  terminal and sudo, so a collaborator could read a running turn's environment; in a shared
  workspace every turn uses the team key, and sharing a workspace switches it over from the next
  turn. The same rule covers a person's own overrides of secrets and environment variables.
  The key is resolved per turn from the prompter. `claude setup-token` tokens are never stored on
  runbloom.app.
- **Later, personal subscriptions** in workspaces that are not shared: the person runs Claude's own
  `/login` or Codex's device login in the Sprite's terminal, the credential stays on that Sprite, and
  sharing the workspace is refused while it is there. A Codex ChatGPT plan `auth.json` is treated the
  same way.

### How a key reaches a turn

Bloom today keeps one long-lived agent process per chat (Claude stream-json with stdin held open,
the Codex app-server) and relaunches with `--resume` or `thread/resume` after a restart. On a
Sprite:

1. **Registering.** A client sends a prompt with a workspace token carrying `prompt`, fresh at the
   moment of sending. Bloom Runner passes that token on at once to `POST
   /api/machine/workspaces/{id}/turns`, and gets back a turn id in state `queued`, stored on the
   delivery. The workspace secret alone cannot get a key: every key is tied to a turn a person
   asked for while their token was valid. Removing a member cancels their queued turns, and a turn
   registered more than 12 hours before it starts is refused.
2. **Starting.** When the delivery reaches the front of the queue, which may be long after that
   token expired, Bloom Runner calls `POST .../turns/{turn}/start` with the workspace secret. The
   reply carries the resolved key, an identity for it (a hash, not the key), and the prompter's
   personal environment. The key is fetched at every start and never cached across turns.
3. If the running process was started with the same identity, the delivery goes to its stdin. The
   identity is the resolved key, not the person, so teammates sharing the team key never cause a
   relaunch.
4. Otherwise Bloom Runner waits for the running turn to end, stops the process and relaunches it
   with `--resume` and the key in the process environment only (`ANTHROPIC_API_KEY`,
   `OPENAI_API_KEY`). Resume reloads the session from local files on the Sprite, which is cheap.
   **The prompt cache is not**: a different key is a cache miss, and the first turn after a switch
   pays full input price for the whole context. That only happens when someone with a personal key
   takes a turn after someone on another key.
5. A message from someone else is never injected into a running turn. It queues behind it.
6. **Ending.** `DELETE .../turns/{turn}` when the turn ends, fails or is stopped.

A running process keeps the key it was launched with for as long as consecutive turns resolve to
the same identity. Personal environment applies only to that turn's processes; it is not given to
project services. A terminal session registers the same way, `POST .../turns` with `kind:
"terminal"` and a token carrying the `terminal` ability, and its
shell gets that person's key, personal environment and GitHub token.

The key is never written to disk, never in argv, and never in the transcript. A cold wake kills
the process, and the next delivery starts again at step 1.

## Collaboration

A workspace is private to its creator until shared with their team, as Amp does it. Phase 1 has
two roles, owner and collaborator; a collaborator can prompt, answer questions, stop a turn, use
the terminal, edit files and open the preview. Only the owner shares, unshares and archives. A
collaborator needs GitHub connected to prompt, because their turns push as them.

The #163 runtime already serves several clients at once, with a durable server-side prompt queue
and last-writer-wins composer settings. What it lacks is who did it: the gateway drops the caller
and messages have no sender. Phase 1 adds:

- **An author on every delivery and every user message**, from the token's `sub`, stored as a
  column and shown on the message. A Store migration, and `update` rather than `upsert` as always.
- **Arrival order.** Prompts from several people queue in the order the server received them. The
  queue is visible to everyone and anyone can cancel a queued prompt, which is recorded.
- **Drafts stay per user and on the client.** Nothing is typed into anyone else's composer.
- **Composer settings** stay last-writer-wins, and the change event names who made it.
- **Questions and permission prompts**: the first answer wins. The runtime already claims a
  request once; a second answer gets "already answered by <name>".
- **Presence**: Bloom Runner keeps the set of users with an open event stream and the last human
  input per user, and publishes it as an event and in the summary.

### Addressing somebody instead of the agent

`@name` at the start of a message means it is for a person and not for the agent. The wire is in
docs/WORKSPACE-PROTOCOL.md; two machine calls make it work.

**`GET /api/machine/workspaces/{workspace}/members`** answers `user_id`, `name` and `handle` for
everybody on the team, and **no addresses**. A share-link guest is on the machine and completion is
offered to whoever is typing, so a directory of every member's email would be a way for somebody
outside the team to read them by typing `@`. That is a different exposure from the `email` on a
message's author, which names somebody whose message the reader can already see. **It is a pull, and
a miss refetches**, because a machine holding a list from three weeks ago refuses a colleague who
joined last week; `MachineMembers` puts a cooldown on that, since a mistyped handle is a miss too
and a request per keystroke is not a well behaved machine.

**`POST /api/machine/workspaces/{workspace}/addressed`** tells runbloom.app somebody was addressed,
so it can mail them if they were not here. **Its own call rather than a fold into a report, because
it causes mail**: anything coalesced, retried for unrelated reasons or replayed sends two emails or
none. It carries the message's own id, when it was sent, who sent it, and **whether each addressed
person was connected at that moment**, which is the fact only the machine holds. The other end
dedupes per message **and addressed person**, so a retry is free, and the id must never be reused:
a repeat is treated as a retry and mails nobody, which fails without a symptom.

**`cloud-workspaces` and `opening` hand a new workspace its first message**, the one written
exception to runbloom.app never carrying agent traffic, approved by Freek on 18 September 2026. The
creating machine sends `prompt` with `controls.agent` and `controls.model` from the chat that asked,
never chosen by the agent, and runbloom.app registers the opening turn for that chat's person with
that agent. The new machine, after setup on every boot, `GET`s `opening`, keeps it in its own
database, `DELETE`s it (so runbloom.app forgets it), and only then queues it under that turn and
person, where it waits behind setup like any prompt and starts through `turns/{id}/start`. **Kept
before acknowledged**, so a machine that stops in between fetches the same opening again; **queued
once per turn**, so a boot that finds its kept copy already queued does not queue it twice. A
missing key in `controls` means the machine's own default for it. See `OpeningHandoff`.

**It carries the words, as `person_message: {"text", "truncated"}`**, so the mail can say what was
asked. Only the message that addressed that person, as typed with its mention, capped at 2,000
characters and 16,000 bytes of UTF-8 and cut between characters, with `truncated` saying so. **The
key names what it is: words one person wrote to another**, never a prompt and never agent traffic;
runbloom.app escapes them, never stores or logs them, and keeps its own 2,000-character cap in the
mail. A report queued before the words were kept goes without the field, and the mail goes out as it
did. Agreed with the control server on 19 September 2026.

**It carries the sender's own session token, as `sender_token`**, the one the words arrived on, so
runbloom.app checks the author against something the machine did not state itself. It refuses the
whole report, and mails nobody, unless the token is its own signature, names this workspace, is a
`session` token whose `sub` is `from.user_id`, carries no `act`, was issued between ten minutes
before `sent_at` and a minute after, and was not revoked since; and `sent_at` is under a day old.
Expiry is not checked, because a report can go late after a restart, which is also why the machine
keeps the token with the report row until it is sent and then clears it. A message to a person never
becomes a turn, so a turn id could not do this. **The limit, stated honestly:** code on the machine
that can read the database can take a live token from it, so this narrows forging to people who were
on this workspace in the last few minutes rather than ending it; running the agent as a user that
cannot read the database is what ends it. Optional until every machine sends it, then required.
Agreed with the control server on 19 September 2026, after the security review's M2.

**A guest's message is reported too, and runbloom.app decides it sends no mail.** The machine says
what happened and the server says what it means, so that policy is one deploy rather than a release
to every machine, and there is an answer when somebody asks how often guests try to reach people who
are away. See `AddressedReporter`: the queue is a table, because a machine that stopped between
writing the message and sending the report would otherwise never send it.

## Awake, asleep, and what it costs

An open stream keeps a Sprite awake, so a Mac left open on a workspace would bill until it was
closed. Bloom Runner therefore decides when it may sleep, and tells clients.

It holds a Tasks API task, renewed by heartbeat, while any of these is true:

- setup or resume is running;
- an agent turn is running, including one waiting on a question (bounded, see below);
- a run script the user started is running;
- the **human presence lease** is live: 15 minutes after the last human input from any client.
  Input is a prompt, an answer, a keystroke in the terminal, a file save, a navigation in the
  preview. An open stream, a visible window or a poll is not input.

The lease is cut short in one case, because it costs one counter the server already has: when the
last client stream closes (the app quit, the workspace closed, the laptop slept), the lease ends two
minutes later if nothing else renewed it. A client that is open but idle is not detected; that would
need every client to report its own visibility, which is more state than the minutes it saves.

When none is true it releases, in this order and never another: post the final summary with
`awake: false` and the usage report, send `sleeping` on every stream and close them, and only then
delete the task. The order is forced by a measurement: a Sprite released from its last task paused
almost at once, not 30 s later, so anything sent after the release may be frozen mid-request.
Clients show the runbloom.app summary and reconnect on the next interaction.

A wake is not always under a second. Through the public URL the first request after a two minute
pause took 4.5 s end to end, and requests after a minute idle took 0.2 to 0.6 s to first byte
against 0.23 s awake. So a client allows at least 10 s for the first request to a sleeping
workspace, shows that it is waking after 500 ms rather than a spinner with no words, and never
treats a slow first response as a failure to retry with a new command id. Project services stay running and freeze with the Sprite, so a Vite HMR
socket in someone's browser does not hold it awake past the lease either: the preview proxy closes
upgraded connections when it sends `sleeping`.

A turn waiting on a question holds the Sprite for at most the presence lease after the question
was asked, then releases it. The question survives the pause; answering wakes the Sprite.

## The protocol

The #163 wire protocol (a tagged JSON envelope, durable command ids, receipts, the operation
inventory in its `docs/SERVER-PROTOCOL.md`) is kept, because its semantics were earned: unknown
outcomes, queued deliveries, revision-checked file writes, archive confirmation. It is **not**
kept compatible: there are no server users, so version negotiation with 12 to 16 goes, and it
starts again as `bloom-workspace` version 1. What changes:

- **One workspace.** Operations lose `workspaceID`, and repository and project operations that only
  make sense on a multi-project server go (`catalogue` becomes `workspace`, `creation`, `project`,
  `storage`, `cleanupStorage`, `skills`, `diagnostics` as it was, Docker fields).
- **Events instead of polling.** #163 clients poll transcripts every second. `GET
  /_bloom/v1/events` is a server-sent event stream: transcript messages by `seq`, streaming text
  as deltas with a snapshot on connect, queue changes, questions, composer changes, setup output,
  review revision bumps, presence, `sleeping`. It resumes from `Last-Event-ID`, which is the
  transcript `seq` it already has, so reconnecting after a pause costs nothing new. Paged
  `transcript` stays for catching up history.
- **Authors** as above.
- **Named fields, not Swift's encoding.** #163's envelope is Swift's synthesised `Codable`, so an
  enum case with an unnamed value is `{"text":{"_0":"..."}}`, dates count from 2001 and failures
  are prose. Version 1 is written for a reader in another language: named fields throughout, ISO
  8601 dates, and failures as `{code, message}` with stable codes. The Swift types encode to that
  shape by hand where synthesis would not.
- **Endpoints**, all on the Sprite URL:

| Path | What |
| --- | --- |
| `POST /_bloom/v1/rpc` | the envelope, bearer token |
| `GET /_bloom/v1/events` | SSE read with `fetch`, bearer token |
| `GET /_bloom/v1/terminal?name=` | WebSocket, `auth` first frame, binary frames, resize and `reauth` text frames |
| `GET /_bloom/preview/enter?token=` | preview cookie exchange |
| `POST /_bloom/v1/control/revoke`, `update`, `environment`, `limits-cleared`, `stop`, `secret-rotated`, `shared` | runbloom.app only, `admin` token |
| `GET /_bloom/health` | unauthenticated, version only |
| everything else | the preview |

## Clients other than the Mac

iOS comes later and a web interface may come after it, so the contract is checked against a
browser now rather than discovered to be native-only then.

- **Streams without headers.** A browser's `EventSource` cannot send `Authorization`. The event
  stream is ordinary SSE framing, read with `fetch` and a `ReadableStream`, which can send the
  header, and which is also how the native clients read it. No token goes in a URL, where it would
  land in logs and history. A browser `WebSocket` cannot send a header either, so the terminal
  WebSocket takes its token as the first text frame, `{"kind":"auth","token":"..."}`, and closes
  unauthenticated connections after five seconds. Every client does the same, so there is one path
  to test. Cookies are not used for control: a cookie would put CSRF on the table and share
  authority with the preview on the same origin.
- **CORS.** `/_bloom/v1/*` answers preflight for the origins pinned in `workspace.json` at bootstrap
  (`https://runbloom.app` to start with), allows `Authorization` and `Content-Type`, never allows
  credentials, and caches preflight for ten minutes. The preview paths send no CORS headers of their
  own; what the app sends is the app's business.
- **The preview in a browser** opens top level through the same exchange. Embedding it in a
  runbloom.app page would need the preview cookie as `SameSite=None; Partitioned`, and that decision
  waits for a web client that wants it.
- **The behaviour a client has to get right is written down, not left in Swift.** The protocol
  document that ships with version 1 has a client chapter covering what #163 kept in
  `BloomClient`: merging transcript pages and events by `seq`, applying streaming deltas over the
  snapshot, keeping and retrying a mutation under its original command id, refreshing a workspace
  token before a stream's expires, reconnecting after `sleeping` and waking the machine, review
  revisions and the patch cache, queue and question state, and presence. It ships with a JSON
  Schema and test vectors generated from the Swift types, as #163 did, so a TypeScript client is
  checked against the same examples as the Swift one.

## Preview

**The preview is opened as a page, never inside a frame, and that is a decision rather than an
omission.** Authorisation is a cookie on the machine's origin, because **nothing can attach a token
to a subresource**: the preview serves somebody's real app and the browser fetches its own images,
scripts and XHR with whatever it has. In a frame on runbloom.app that cookie is third party, which
Safari blocks outright and Chrome is part way through removing, so the enter would succeed and
everything after it would arrive unauthenticated, **looking like a broken app rather than a blocked
cookie**. `SameSite=None` plus the Storage Access API would work in one browser today and needs a
prompt; a first-party page works in all of them with the code that already exists. The Mac's pane is
a `WKWebView`, which is first party already, so it needs nothing special; a browser client opens a
tab.

**If an embedded preview ever matters more than a tab, the design is a proxy and not a cookie
policy**: runbloom.app serves the preview path itself and forwards to the machine, so the frame is
same origin with the page around it and no machine cookie is involved at all. It costs every preview
byte and every Vite socket going through the control server. **Written here so nobody arrives at the
proxy as a workaround for a blocked cookie**, which is the route that ends in `SameSite=None` and a
year of browser-specific bugs.

**And the machine not refusing a frame is not the same as a frame working.** Nothing here sets
`X-Frame-Options` or `frame-ancestors`, but the project's own app does: Laravel, Rails and Next all
ship something in some configuration, so "can this be framed" would be a per-project question
answered silently at runtime.

The Sprite URL has one port, so it cannot give control and the preview separate origins. A Caddy
supervised by Bloom Runner listens on it and routes `/_bloom/*` to Bloom Runner and everything else
to the project's app on `BLOOM_APP_PORT`. Caddy rather than a proxy in Swift, because streaming,
WebSocket upgrades for Vite and Reverb, and header rewriting are what it is for, and the
There There spike already ran one.

Control never reads cookies; it wants `Authorization: Bearer`. The preview wants the
`__Host-bloom-preview` cookie (HttpOnly, Secure, SameSite=Lax, eight hours, bound to a user),
checked by Caddy's `forward_auth` against Bloom Runner, stripped before the request reaches the
app, and refused if the app tries to set it. So the app's own JavaScript shares an origin with
control and still cannot reach it. A client opens the preview through `GET
/_bloom/preview/enter?token=<60 s single-use preview JWT>`, which sets the cookie and redirects. A share
link is `https://runbloom.app/share/<id>`: runbloom.app checks the share is live, mints a 60 s
preview token for `sub: "share:<id>"` and redirects to the exchange, which sets a cookie lasting
one hour rather than eight. There is no long-lived share token.

**A project that serves on its own port is told so.** The preview proxies to `BLOOM_APP_PORT`,
which every script is handed, and a project whose dev server listens elsewhere used to get a page
saying the app was not answering: true, and no help at all, because nothing said there was an agreed
port. One workspace served on 8091 while the preview read 3000, and an agent spent twenty-odd
actions building a second proxy to bridge them. The unavailable page now names the port it reads,
says nothing is listening there, and lists the ports that are, leaving out Bloom's own so nobody is
sent to proxy the preview at itself. The ports come from `/proc/net/tcp`, not from running `ss`: it
is an HTTP handler, and a subprocess in one is a hang waiting to happen.

## Setup

Every create is cold. A Sprite cannot start from another's checkpoint, and phase 1 has no pool of
prepared machines, so Bloom Runner runs the whole of it in one go after bootstrap: clone with a
read-only installation token, create the branch, `scripts.prepare`, `scripts.setup`,
`scripts.resume`, then the services, reporting each step in the summary. For There There that is
about two and a half minutes, most of it apt. The opening prompt queues behind setup, as it does
locally.

runbloom.app keeps a Machine record per Sprite, named `bloom-<machine ulid>`. The Sprites HTTP API
cannot set labels, so the mapping from Sprite to workspace lives in its database, and the orphan
sweep deletes a Sprite no Machine owns only when its whole name matches
`^bloom-[0-9a-hjkmnp-tv-z]{26}$`, never on the prefix alone.

Production Cloud workspaces run in a Fly organisation of their own, created and billed separately.
Development and tests run in another, which is the one the Sprites CLI on the owner's Mac is signed
in to; the test tools take its name from `BLOOM_TEST_SPRITES_ORG` rather than from this repository.
There is no staging environment: end-to-end testing runs against runbloom.app itself behind its
access and configuration switches. The names keep machines apart as well, so a mistake in which
organisation a tool points at still cannot touch the wrong machine. Machines created by local
development are named `bloomdev-<...>` and by automated tests `bloomtest-<...>`; neither starts with `bloom-`, so
the production sweep cannot match them however it is written, and nothing that creates or sweeps
development or test machines can match a production one. A test deletes what it created in its
own teardown, and `Tools/sweep-test-machines.sh` deletes `bloomtest-` machines older than a day for
the runs that crashed before theirs.

**Later, a warm pool.** Because `prepare` is already its own script with no secrets, a pool of
machines that ran it and paused is an addition on runbloom.app's side plus a claim step in
Bloom Runner (reread configuration, rotate the secret, create the branch, carry on from `setup`).
Nothing in phase 1 has to change for it.

The repository side, in `.bloom/settings.toml`, alongside the setup scripts that exist today:

```toml
[scripts]
prepare = ".bloom/prepare.sh"   # machine: apt, runtimes, dependencies, database server; no secrets
setup = ".bloom/setup.sh"       # this workspace: env file, migrate and seed, build
resume = ".bloom/resume.sh"     # after every wake, with fresh environment

[[services]]
name = "app"
command = "php artisan octane:start --port=$BLOOM_APP_PORT"
http = true                     # the one the preview routes to
ready = "http:/up"

[[services]]
name = "vite"
command = "npm run dev"
depends_on = ["app"]

[remote]
size = "default"                # a hint; runbloom.app decides
```

Bloom injects into every script and service: `BLOOM_PUBLIC_URL` (the Sprite URL, Amp's
`PUBLIC_URL`), `BLOOM_PUBLIC_HOST`, `BLOOM_APP_PORT`, `BLOOM_WORKSPACE_ID`, `BLOOM_BRANCH`, plus
the team and project environment runbloom.app holds. The repository maps them itself
(`APP_URL=$BLOOM_PUBLIC_URL`, Vite's allowed hosts from `BLOOM_PUBLIC_HOST`). Team and project
values arrive at setup and at every resume; personal values arrive only with a turn or a terminal
session, apply only to its processes, and, like personal keys, are delivered only in a workspace
that is not shared. All of it lives only in process environments; a script
that writes it into `.env` has made that choice itself.

Project services run under Bloom Runner's own supervisor, not as Sprite Services. A Sprite Service
restarts on its own on cold wake, before `resume` has fetched fresh environment, and cannot be
deleted while another depends on it. Bloom Runner is the only Sprite Service, and it starts the
rest after `resume`.

Setup runs natively. Docker is not supported on Sprites, for the measured reasons above.

## GitHub

runbloom.app adds a GitHub App with user authorisation. The Sprite never holds a long-lived token:
`git` is configured with a credential helper, and `gh` with a wrapper, that ask Bloom Runner, which
asks runbloom.app for a short-lived token. During a turn or a terminal session that is a user token
for the person who started it. Outside one (prepare, setup, resume) it is an installation token for
that one repository with read-only contents. There is no fallback to the owner's token. Nothing is
written to disk. Pushes and pull requests are made as the person who asked for them. Commit signing
is out of scope for phase 1.

## Usage

runbloom.app meters usage per team and enforces per-team limits, so Bloom Runner reports what the
provider bills for, in provider-neutral terms. The fields are agreed with runbloom.app pull request #23.

`POST /api/machine/workspaces/{id}/usage` with the workspace secret, separate from the summary
because it is append-only where the summary is replace-latest:

```json
{
  "machine_boot_id": "…",
  "sequence": 118,
  "events": [
    {"kind": "awake", "at": "2026-09-17T09:40:02Z", "reason": "human_input"},
    {"kind": "setup_started", "at": "…"},
    {"kind": "setup_finished", "at": "…", "outcome": "succeeded"},
    {"kind": "turn_started", "at": "…", "turn_id": "…", "user_id": "…", "agent": "claude"},
    {"kind": "turn_finished", "at": "…", "turn_id": "…"},
    {"kind": "released", "at": "2026-09-17T10:15:00Z"}
  ],
  "counters": {
    "cpu_seconds": 5310.4,
    "memory_gb_seconds": 21044.0,
    "awake_seconds": 2098.0
  },
  "disk": {"used_bytes": 7340032000, "at": "…"}
}
```

- **Awake and released.** `awake` is when Bloom Runner takes its first hold, with the reason (setup,
  turn, script, human input); `released` is when it lets go of the last one. Measured, the Sprite paused almost immediately after
  the release, so `released` is close to the true pause; runbloom.app's added margin covers the
  case where an idle open connection kept it awake a little longer, and the provider's own state is
  the reconciliation. A wake after a pause
  is detected as a wall clock gap and reported as `awake`.
- **Counters are cumulative** since boot, so a lost or repeated report changes nothing: runbloom.app
  takes differences between sequences within one `machine_boot_id`. `cpu_seconds` is non-idle time
  from `/proc/stat`; `memory_gb_seconds` integrates `MemTotal - MemAvailable` sampled every 15 s
  while awake. Both are what the provider bills for, measured from inside.
- **Disk** is used bytes on the machine's filesystem, hourly while awake and at every release,
  because storage bills whether awake or not.
- **Turns** carry the user, so limits can be per person as well as per team.

Sent at every `released`, every 5 minutes while awake, and on shutdown. runbloom.app adds a margin
after each `released` for a pause it cannot see (its own configuration, five seconds, given the measurement above), carries storage forward from the last disk
report until the machine is deleted, and checks machine state against the provider's API on its
own, because anyone with root on the machine could stop or falsify these reports. The reports are
for showing usage and enforcing limits early, not the only source of truth.

### When runbloom.app cannot be reached

Everything else that can go wrong between a machine and runbloom.app fails in front of somebody. A
prompt that cannot start pauses its chat with a sentence; a push with no credential says so. Reports
fail quietly, because nobody is waiting on one, which is why this is the only part of the
arrangement that used to be unbounded and invisible at the same time.

**Measured first, on a machine.** A workspace in use posts a usage report every five minutes while
it is held awake, and one summary whenever something a person would notice changes. A quiet report
is 209 bytes, one carrying twenty turns is 2.5 kB, and the largest runbloom.app will accept is
145 kB (`RemoteUsageMeter.eventsPerReport`, a thousand events). So an hour of outage on a busy
machine is about 30 kB and a day is under a megabyte: the memory was never the emergency. The
silence was.

**The backlog is capped at four megabytes and sheds its oldest.** At the sizes above that is ten
weeks of a quiet machine, six days of a busy one, and two and a half hours of one reporting at the
ceiling, all of them longer than a machine stays awake. What goes first is the oldest report,
because the counters are cumulative and the newest one carries the totals: what a workspace cost
stays right, and what is lost is the account of which turns made up the oldest hours.
`RemoteUsageMeter.record` already sheds its oldest events at two thousand for the same reason, and
this is the same rule one layer up. **A summary is never shed**, because there is only ever one:
it is replace-latest, so a newer one simply takes the older one's place.

**And the machine says so, to three different readers.** The workspace record carries `reporting`
with `unreachable_since` and `shed` whenever there is something wrong to say, so a client can tell
the person sitting in the workspace that what they are doing is not being recorded, and since when.
The service log gets a line with the queue's depth in bytes, for whoever reads a machine
afterwards. And runbloom.app is told about shedding as a `reports_shed` event, whose `count` is
cumulative, once it can be reached again: a hole in its account of a machine should be a hole it
knows about rather than hours that merely look quiet.

Nothing here is restart-proof, and that is deliberate. An unsent report dies with the process,
because the counters it carries are cumulative and the next report from the same boot covers them;
only its events are lost, which is the same loss shedding accepts.

**Measured on a machine**, with `machine-test.py --outage`: twenty-two minutes of refused reports
while the workspace was in use took the server from 59.8 MB resident to 62.3 MB, most of that in
the first two minutes and none of it the queue, which held four reports. When runbloom.app came
back, every one of them arrived, in order, with contiguous sequences, and the one owed summary with
them. Before this change the service log said nothing about any of it and a client could read
nothing about it either, which is the whole reason `reporting` exists.

## Limits

runbloom.app enforces per-team limits at three points: creating a workspace, issuing a workspace
token (which reserves a slot against the awake limit, and wakes nothing: the client's own first
request to the machine URL is what wakes a sleeping machine, because answering is waking), and
starting a turn. Archive is never refused. A
refusal is:

```json
{"code": "limit_reached", "limit": "concurrent_machines", "message": "…", "retry_after": 60}
```

`limit` is `monthly_usage`, `concurrent_machines`, `total_machines` or `kill_switch`. Only
`concurrent_machines` is HTTP 429 and carries `retry_after`, because only it clears by itself when
another machine in the team goes to sleep; the others are 403 and need a person or a new month.

**A refused turn start.** runbloom.app marks the turn blocked. Bloom Runner keeps the prompt
queued, shows it as blocked with the reason on the event stream and in the summary (`state:
"blocked"`, `blocked: {limit, message}`), and releases the machine so it can sleep. It does **not**
poll to find out when the limit lifts, because polling keeps the machine awake and billing, which is
the thing the limit is for. Instead runbloom.app calls `POST /_bloom/v1/control/limits-cleared`
(control token for that workspace) when a limit lifts: a machine in the team released (oldest
blocked turn first), an administrator raised a limit, the kill switch went off, a month began. That
call wakes the machine, and Bloom Runner retries the start. As a fallback it also retries whenever
it wakes for any other reason.

**Kill switch or overage while awake.** runbloom.app first calls `POST /_bloom/v1/control/stop`
with the limit. Bloom Runner stops a running turn the way Stop does, marks queued prompts blocked,
posts its summary and usage, and releases. After a grace of 30 s a scheduled job stops the
machine's services through the provider regardless, and Bloom Runner treats the `SIGTERM` that
brings the same way: stop the turn, flush the reports it can, exit. A turn cut off like that is
recorded in the transcript as stopped by a limit, not as a failure.

**In the Mac app** the message is shown as runbloom.app wrote it, in Cloud workspace wording, and
the two kinds look different: `concurrent_machines` says it will carry on by itself once another
Cloud workspace in the team goes to sleep, and the queued prompt shows as waiting; the others say
what has to happen and who can make it happen, and the prompt shows as blocked. A refused create or
wake shows the same message where the create or the open was attempted.

## Summaries

Bloom Runner posts `POST /api/machine/workspaces/{id}/summary` with the workspace secret. A
monotonic `revision` means a late post never overwrites a newer one.

```json
{
  "revision": 42,
  "observed_at": "2026-09-17T10:00:00Z",
  "bloom_runner_version": "0.9.0",
  "title": "Queue retries",
  "branch": "freek/queue-retries",
  "base_branch": "main",
  "state": "running",
  "awake": true,
  "presence_lease_until": "2026-09-17T10:15:00Z",
  "setup": {"state": "succeeded", "step": null, "started_at": "...", "finished_at": "..."},
  "last_message": {"chat_id": "...", "author_kind": "agent", "author_user_id": null, "excerpt": "...", "at": "..."},
  "waiting": null,
  "running_since": "2026-09-17T09:58:12Z",
  "diff": {"files": 4, "additions": 120, "deletions": 8},
  "pull_request": null,
  "chats": [{"id": "...", "title": "...", "agent": "claude", "state": "running"}],
  "present_user_ids": ["..."]
}
```

`state` is one of `setting_up`, `setup_failed`, `idle`, `running`, `waiting_for_input`, `blocked`,
`stopping`, `error`. `waiting` is `{kind: permission | question | plan, chat_id, since}` when set.

`last_message` changes only when a message completes, never per streamed chunk, so a running turn
does not post every two seconds.

Posted at once on a turn starting or ending, waiting starting or being answered, a setup step, a
title, branch or pull request change, an error, and going to sleep; coalesced to one post every two
seconds; diff and presence changes at most every 30 s. Delivery retries with backoff and a newer
summary replaces an unsent older one. Unread is per user and computed on runbloom.app from
`last_message.at`. Push notifications fire on transitions into `waiting_for_input`, a turn ending
and `setup_failed`.

Clients poll the list from runbloom.app on focus and every 15 to 30 s while visible, plus APNs. No
WebSockets on runbloom.app in phase 1; if Reverb arrives later it carries the same payload.

## Installing and updating Bloom Runner

A release of this repository publishes `bloom-runner-linux-x86_64-<version>.tar.gz` with a sha256
manifest: `bloom-runner`, `bloom-bridge`, Caddy, and the Swift runtime libraries with an `$ORIGIN`
rpath, as #163's `Tools/package-linux-runner.py` already builds them.

runbloom.app bootstraps a new Sprite with one exec: download the version it chose, verify the
checksum, unpack into `/opt/bloom/<version>`, point `/opt/bloom/current` at it, write
`/etc/bloom/workspace.json` with the workspace id, the issuer, the JWKS URL, the allowed web
origins and the workspace secret, and create the service once:

```sh
sprite-env services create bloom --cmd /opt/bloom/current/bin/bloom-runner --args serve --http-port 8080 --no-stream
```

The command never changes, because creating a service under an existing name keeps the old
definition. Updating is therefore the same exec for a newer version, which moves the symlink and
restarts the service, run by runbloom.app only when the summary says the workspace is idle and the
reported version differs. The script does not put the symlink back itself: the restart it asks for
kills it. Two things undo a release that will not start, and both write the same symlink, so
running both is harmless. The machine's own half is the start wrapper (below). runbloom.app's half
is polling `/_bloom/health` and reaching in through the provider when the machine has not healed
itself, which is the case the machine cannot see about itself. **Never delete
`/opt/bloom/<previous version>`:** both reverts point the symlink at a directory that is already
there and download nothing, which is what makes them work when the network or the disk is the
problem.

## Archive and restore

Archive deletes the machine, and with it the conversation. It is confirmed the way #163 confirms
it, a preview with hazards and then a confirmation id:

1. The preview reports unpushed commits and uncommitted changes, as today, and says that the
   conversation is deleted with the Cloud workspace.
2. Bloom Runner stops its turns and services and posts a last summary and usage report.
3. runbloom.app deletes the machine and revokes the secret.

Restore is a new Cloud workspace on the same branch. Anything that was not pushed is gone, which
the preview said.

**Later, an export.** Before deleting, Bloom Runner would upload the transcript and the agents'
own session files (`~/.claude/projects/...`, Codex rollouts) to runbloom.app, and a restore would
write them back before the agent starts, so the conversation resumes.

## The machine-facing endpoints on runbloom.app

No provider name in any path. All take the workspace secret except where noted.

| Endpoint | Used for |
| --- | --- |
| `POST /api/machine/workspaces/{id}/summary` | summaries |
| `POST /api/machine/workspaces/{id}/usage` | usage reports |
| `GET /api/machine/workspaces/{id}/environment` | team and project environment, at setup and resume |
| `POST /api/machine/workspaces/{id}/turns` | registering a turn or terminal session, with the user's workspace token as well |
| `POST /api/machine/workspaces/{id}/turns/{turn}/start` | the key and personal environment, or a limit refusal |
| `DELETE /api/machine/workspaces/{id}/turns/{turn}` | ending a turn or terminal session |
| `POST /api/machine/workspaces/{id}/git-credentials` | a short-lived GitHub token for the current turn, or read-only outside one |
| `GET /.well-known/jwks.json` | public, the key set for workspace and control tokens |

Clients use `POST /api/v1/cloud-workspaces/{id}/session-token` and the rest of `/api/v1/cloud-workspaces`, which accepts a
Passport token or, for the web interface, the browser session.

## Where the code goes

- `Packages/BloomProtocol` is new: the version 1 wire records, operations, events and error codes,
  plain Foundation and nothing else. The server and every Swift client depend on it, so neither has
  to import the other to agree on a shape. #163 proposed this target and never made it, and its
  clients carried wire types inside `BloomClient` instead, which is how the server came to depend on
  a client package.
- `Sources/BloomCore` stays free of networking servers. The single-workspace runtime, the prompt
  queue with authors, presence, the awake policy as a pure state machine, the summary builder and
  coalescing, usage counters, and the settings for `prepare`, `resume` and `[[services]]` go here,
  grouped under a new `Remote/` subject, testable with no Sprite.
- `Sources/BloomRunner` is a new library target, Linux and macOS, owning the HTTP front
  (Hummingbird 2 on SwiftNIO), token verification, the SSE and WebSocket endpoints, CORS, the
  provider implementation, the Caddy and service supervisor, and the runbloom.app client. The Mac
  app does not link it. `Tests/BloomRunnerTests` depends on it.
- `Sources/bloom-runner` is its `main.swift`.
- `Packages/BloomClient` (Mac client pull request) holds what a Swift client needs beyond the wire
  shapes: the workspace connection, event stream reader, transcript merging, the outbox, the review
  and composer stores. `Packages/BloomAuthentication` holds sign-in.
- The provider-specific surface inside the machine is one protocol, `MachineHost`: hold awake and
  release, the public URL, and where usage is read from. Sprites are its first implementation;
  Daytona or E2B later is another. Create, wake, exec, filesystem, delete and URL are runbloom.app's,
  behind its own provider interface. No type outside that implementation is named after Sprites.

`make lint` gains a rule that `BloomCore` imports no NIO, and CI gains a Linux job that builds
`bloom-runner` and runs `BloomCoreTests` and `BloomRunnerTests` in `swift:6.3-noble`.

## Two pull requests, and what comes from #163

Both start from main in new branches. #163 is read with `git show
origin/freekmurze/client-server-runtime:<path>` and ported file by file; nobody branches from it and
deletes the SSH code, because its Linux work is spread through feature commits and merges, and
because main has moved on under it. Every file that comes across is read against main's version of
its neighbours before it lands. Each step below leaves `make build`, `make lint`, `make swiftlint`
and CI green.

In the lists, **port** means bring across and adapt to main, **rewrite** means #163's file is the
reference for behaviour but the code is new, and **leave** means it stays in #163.

### Pull request 1: the server

**Step 1, Linux base.** Reference commits `c3a6c577`, `fe69f40f`, the Linux parts of `7b66cfe6`,
`c02d47f2` and `5aada145`.

| #163 path | |
| --- | --- |
| `Package.swift` Linux section, `Sources/CSQLite/` | port |
| swift-crypto dependency, and wherever core code imports `CryptoKit` | port |
| `Sources/BloomCore/System/SystemCalls.swift`, `ProcessLaunch.swift`, `CoreLogger.swift`, `ProcessPipeReader.swift` | port (new on main) |
| Linux changes to `StreamingProcess.swift`, `Shell`, `Git`, the `#if canImport` guards in `Presentation/` and the bridge socket | port, as edits to main's files |
| `.github/workflows/server.yml` | rewrite, as a Linux job in `test.yml` |
| `Tests/BloomCoreTests/ProcessLaunchTests.swift` | port |

**Step 2, runtime core for one workspace.**

| #163 path | |
| --- | --- |
| `Sources/BloomCore/Server/ServerProtocol.swift`, `ServerOperation+Workspace.swift`, `ServerWorkspaceAction.swift` | rewrite as `Packages/BloomProtocol`, version 1, named fields |
| `ServerRuntime.swift` | rewrite, single workspace, keeping the receipt journal and admission logic |
| `ServerSession.swift`, `ServerPromptQueue.swift`, `ServerWorkspaceAdmissions.swift`, `ServerWorkspaceOperations.swift` | port, adding authors and turn registration |
| `ServerReview.swift`, `ServerReviewCache.swift`, `ServerReviewWatch.swift`, `ServerReviewFileStamp.swift`, `ServerWorkspaceReviewReader.swift`, `ServerDiffWorktree.swift` | port |
| `ServerComposerState.swift`, `ServerAgentAuthentication.swift`, `ServerFileOperations.swift`, `WorkspaceFileAccess.swift`, `ServerSetupOutput.swift` | port |
| `ServerTerminalService.swift`, `ServerTerminalStreams.swift`, `ServerTerminalProcessLifetime.swift` | port; the relay is replaced by the WebSocket in step 3 |
| `ServerProjectSettings.swift` | port, extended with `prepare`, `resume` and `[[services]]` |
| `ServerCreation.swift`, `ServerRepositoryResolver.swift`, `ServerSidebar.swift` | rewrite; creation is a bootstrap step now, not an operation |
| `ServerDaemon.swift`, `RunnerCommandLine.swift` | rewrite as `bloom-runner serve`, no Unix socket, no `connect` |
| Tests: `ServerRuntimeTests`, `ServerWorkspaceTests`, `ServerWorkspaceAdmissionsTests`, `ServerReviewTests`, `ServerReviewCacheTests`, `ServerReviewLifecycleTests`, `ServerCrewQueueTests`, `ServerAgentAuthenticationTests`, `ServerCodexSpeedTests`, `ServerProjectSettingsTests`, `ServerTerminalStreamTests`, `ServerProtocolVectorTests` | port with the code they test |
| `Protocol/generate-schema.py`, `Protocol/verify.py`, `Protocol/examples/` | port for version 1; the v13 to v16 schemas and vectors are left |

**Step 3, Bloom Runner on a machine.** All new code in `Sources/BloomRunner`: HTTP front, tokens,
event stream, terminal WebSocket, CORS, awake policy and `MachineHost` for Sprites, turn
registration and credentials, git credential helper and `gh` wrapper, services supervisor, setup
steps, summaries and usage, preview exchange with Caddy, `control/*`. References from #163:

| #163 path | |
| --- | --- |
| `Gateway/internal/gateway/` (RPC and terminal WebSocket handling, header and cookie stripping, its tests) | rewrite in Swift; the Go gateway is left |
| `ServerHTTPTransport.swift`, `ServerOAuthMetadata.swift` | leave; the server verifies runbloom.app tokens, it is not an OAuth resource server with discovery |
| `ServerPreview.swift`, `ServerPortForward.swift` | rewrite as the Caddy route and preview exchange |
| `ServerUIBroker.swift`, `ServerUIBridgeTools.swift` | leave for phase 1; agent UI tools on a remote client come later |
| main's `Sources/BloomCore/Bridge/` `BridgeServer`, `BridgeShim`, `BridgeDispatch`, `BridgeRegistry` and the in-workspace tools: `ChatListTool`, `ChatReadTool`, `WorkspaceDiffTool`, `WhoamiTool`, `CrewTools` (agent start, say, list, stop) | port to run inside Bloom Runner, scoped to its one workspace. Browser, pane, terminal pane, project and cross-workspace tools are not offered |
| `docs/SERVER-PROTOCOL.md` | rewrite as `docs/WORKSPACE-PROTOCOL.md`, with the client chapter |

**Step 4, packaging.**

| #163 path | |
| --- | --- |
| `Tools/package-linux-runner.py`, `Tools/test-linux-server-package.py`, `Tools/runner-licences/` | port, adding Caddy and its licence |
| `Tools/server-release-assets.py`, `Tools/test-server-release-assets.py`, the Linux asset in `release.yml` | port |
| `Tools/runner-smoke.py` | rewrite as a smoke test that boots `bloom-runner` with a test issuer |
| new `Tools/bootstrap-machine.sh` | the one exec runbloom.app runs |

**Left behind in #163 for good**, and not to be ported by accident:

- `Tools/install-Bloom Runner.py`, `install-bloom-docker.py`, `install-bloom-swap.py`,
  `install-bloom-browser.py`, `bloom-maintenance.py`, `bloom_maintenance_*.py`, `bloom_swap_state.py`,
  `bloom_install_process.py`, `prepare-server-service.py`, `embed-server-setup.py`, and their tests
- `Sources/BloomCore/Server/`: `ServerSetupSSH`, `ServerSetupConnection`, `ServerSetupDiagnostics`,
  `ServerSetupFailure`, `ServerSetupStream`, `ServerConnectionProfile`, `ServerConnectionShelf`,
  `ServerConnections`, `ServerEndpoint`, `ServerClient`, `LocalServerIdentity`, `ServerLockWait`,
  `ServerCredentialImport*`, `ServerDocker*`, `ServerStorage*`, `ServerSkill*`, `ServerSkills*`,
  `ServerMaintenance*`, `ServerUpdate*`, `ServerToolUpdates*`, `ServerRemoval`, `ServerDiagnostics*`,
  `ServerTerminalRelay`, `PaneStateNamespace`
- `Packages/BloomSSH`, `Gateway/`, `Protocol/maintenance-v1.schema.json`, `docs/SERVER.md`,
  `docs/SERVER-MAINTENANCE.md`, `.github/workflows/gateway.yml`

### Pull request 2: the Mac client

| #163 path | |
| --- | --- |
| `Packages/BloomAuthentication` | port; the Mac redirect becomes `bloom://oauth/callback` |
| `Packages/BloomClient/.../RemoteWireSession.swift`, `RemoteCommand.swift`, `HTTPSConnection.swift`, `Connection/` | rewrite against `BloomProtocol` and the event stream; no version negotiation |
| `ConversationDraftStore.swift`, `TranscriptBuffer.swift`, `Transcript/RemoteTranscriptProjection.swift` | port, merging events by `seq` |
| `Review/WorkspaceReviewStore.swift`, `Review/RemoteReview.swift`, `Review/WorkspaceReviewReading.swift` | port |
| `Composer/RemoteComposerStore.swift`, `Composer/RemoteComposerState.swift` | port |
| `Terminal/HTTPSTerminalConnection.swift`, `Terminal/RemoteTerminalConnection.swift`, `Terminal/RemoteTerminalAttachment.swift` | port, with the `auth` first frame |
| `RemoteApproval.swift`, `RemoteApprovalSubmission.swift`, `AgentQuestion.swift`, `AgentQuestionDraft.swift`, `WorkspaceSafetyReport.swift`, `ArchiveHazards.swift` | port |
| `Sources/Bloom/State/AppModel+RemoteServers.swift`, `ServerReviewModel.swift`, `ServerFileBuffer.swift`, `System/ServerAuthentication.swift` | rewrite for workspaces listed from runbloom.app |
| sidebar remote sections, `Views/Server/RemoteTerminalView.swift`, `RemoteFilePreviewView.swift` | rewrite, as Cloud workspaces inside the existing sidebar and panes |
| `Composer/`, `Review/`, `Tools/`, `Presentation/`, `Transcript/` files that are moves of main's own `BloomCore` types (`AgentKind`, `DiffParser`, `MarkdownParser`, `ToolPresenter` and the like) | leave; those moves are for sharing with iOS and wait for the iOS pull request |
| `ServerWindowModel*`, `ServerSetupModel`, `ServerMaintenanceModel*`, `ServerStorageModel`, `ServerSkillsModel`, `ServerCredentialImportModel`, `ServerDockerRecoveryModel`, `ServerToolUpdatesModel`, `RemoteServersSettings*`, `Design/Server*Probe` | leave |
| `Packages/BloomUI`, `iOS/`, `Tools/ios-*`, `.github/workflows/ios.yml` | leave, for the iOS pull request |

### After these two

Later pull requests, roughly in this order: the iOS app over HTTPS (#163's UIKit app is SSH first,
so it is reworked rather than ported), browser and pane tools for agents on remote clients,
personal subscriptions signed in on the machine, the warm pool, the archive export, agent bridge
tools across workspaces through runbloom.app, per-project egress allowlists, Reverb, a read-only
viewer, other providers. The web interface is
built in runbloom.app against the same contract.

### Testing turns during development

Live turns use the developer's own Anthropic API key, the personal key path: supplied through the
environment of the test run (`BLOOM_LIVE_ANTHROPIC_API_KEY`), handed to Bloom Runner by a fake
control server in the test the way runbloom.app would hand it over, and never committed, logged or
written into a fixture. Like `BLOOM_LIVE=1` today, it costs money and is off unless set.


## Verified on a real Sprite

Measured on real Sprites before implementation started, as the owner asked.

- **Verified:** a Sprite's URL is made public at create through the API (`url_settings: {"auth":
  "public"}`), and can be changed later.
- **Verified:** `sprite exec` and Services run as the unprivileged user `sprite` (uid 1001) with
  passwordless sudo. Postgres `initdb` and a server ran as that user, and the #163 checks that
  refuse root are satisfied.
- **Measured, not relied on:** after about 600 s idle, with the API reporting cold, a background
  process was still alive and the wake took 0.4 s, contrary to the documentation. The design keeps
  to the documented case, where memory is dropped.
- **Verified:** SSE through the public URL, 60 events over five minutes with no gaps, and a sparse
  stream with 100 s of silence between events stayed open, so there is no proxy idle timeout at
  that length.
- **Verified:** a WebSocket through the public URL survived 150 s of complete silence with no pings
  either way.
- **Verified:** a Sprite Service's process (uid 1001) reaches `/.sprite/api.sock`, creates and
  deletes tasks, and a held task kept the Sprite running for 150 s with no connections at all.
  After the release it paused almost immediately, which is why releasing sends everything first.
- **Measured:** the first request through the public URL after a two minute pause took 4.5 s; see
  the awake section for what a client does about it.

## Decided by the owner

- The person who prompts supplies the credential. A team key is the default and a personal key
  overrides it for that person's turns.
- A person can belong to several teams, and signs in to runbloom.app with Google or GitHub.
- The presence lease is 15 minutes.
- No warm pool in phase 1; every create is cold.
- No viewer role in phase 1.
- Personal keys only in workspaces that are not shared.
- The in-workspace bridge tools are in the server pull request; browser, pane and cross-workspace
  tools later.
- Archive deletes the machine and the conversation; the export comes later.
- The unverified Sprite facts are measured before implementation starts.
- iOS later, with the contract kept usable by iOS and a web interface.
- Fly and Sprites are invisible to users: one organisation and one token, owned by runbloom.app.
- Two pull requests, server then Mac client, each from main, porting from #163 selectively.
- The user-facing name is Cloud workspace.
- Production runs in its own Fly organisation; development and tests run in another, and machine
  name prefixes keep them apart as well. No staging environment.
  Nothing on the machine depends on which organisation it is in.
- A web interface, when it comes, lives in runbloom.app on the same accounts and this contract.

## Decided while building

Taken while building the server pull request, where this document or runbloom.app pull request #23
left a choice open or the two disagreed. The coordinator relayed the ones that touch runbloom.app,
and its builder confirmed them.

- **The preview exchange takes `?token=`**, runbloom.app's spelling, not `?t=`.
- **Agents are named by their executable on every wire**: `claude`, `codex`, `grok`. Never
  `claudeCode`, which is a Swift case name.
- **Control paths are hyphenated**: `POST /_bloom/v1/control/limits-cleared`, beside `revoke`,
  `update`, `environment` and `stop`.
- **`/etc/bloom/workspace.json`** holds `workspace_id`, `issuer`, `jwks_url`, `base_url`,
  `workspace_secret` and `allowed_origins`. Ids on every wire to runbloom.app are lowercase ULIDs.
- **The release margin is runbloom.app's configuration** (five seconds there), not a number this
  document fixes.
- **The summary carries what is at stake, and leaves it out when it does not know.** `uncommitted`,
  `untracked` and `unpushed_commits` are counts measured beside the diff, from one `git status` and
  one `rev-list`, so the archive confirmation can say "7 files not pushed" rather than warning in
  the same words every time. They are apart from `diff` because `diff` measures against the merge
  base and adds pushed commits, unpushed commits, uncommitted changes and untracked files into one
  number: above zero on nearly every workspace, and zero on a branch whose commits cancel out
  against the base, which is the confidently wrong answer. When git cannot be asked the three keys
  are absent rather than zero, because a zero reads as "nothing at stake" and somebody will archive
  on the strength of it. **A branch with no remote at all counts every commit as unpushed**, which
  overstates rather than understates: this number exists to stop somebody throwing work away, so
  being wrong upwards is the direction to be wrong in, and a change that makes it exact by
  sometimes answering zero would be a worse number. See `RemoteWorkAtStake`.
- **The machine API payloads are runbloom.app's**, recorded under "Machine API payloads" in its
  design document: `turns` takes `kind`, `session_token`, `chat_id` and `agent`; `start` answers
  `agent_keys` (per agent: `key`, `identity`, `source`) and `environment`, or the limit refusal, or
  `no_agent_key`, `not_a_collaborator`, `github_not_connected`, or 409 `turn_not_startable`;
  `git-credentials` takes `repository`, `operation` (`read` or `write`) and `turn_id`, and answers
  `token`, `expires_at` and `username`. `control/update` carries `version`, `sha256` and `tag`, and the
  machine downloads the asset from that tag, `v<version>` for a Bloom release or `runner-v<version>`
  for a runner-only test release, which `release.yml` builds without the app. Any other tag is refused.
  Since the repository went private on 19 September 2026 it also carries `download_url`, a
  short-lived signed URL runbloom.app resolves with its own credential; the machine fetches exactly
  that, from a GitHub asset host only, with no redirect followed and without logging it, and an
  expired one fails the update for runbloom.app to send again (`MachineUpdate`).
- **Version 1 lays a tagged value out flat, except a whole record.** An operation is one object
  with `kind` and its fields beside it. A result or an event that carries a record puts it under a
  key named after the kind, `{"kind": "transcript", "transcript": {...}}`, because a transcript
  row has a `kind` of its own and spreading it overwrote the tag. The Swift types are
  `WorkspaceOperation` and `WorkspaceEvent`, since `Operation` is taken by Foundation.
- **The event stream's cursor is the transcript row id, not `seq`.** `seq` counts within one chat
  and a workspace has several, so `id:` and `Last-Event-ID` carry the row's id, which SQLite hands
  out in increasing order and never reuses. Every row on the wire carries both.
- **A message is never written into a running turn, on any backend.** On the Mac a Codex chat
  takes a second message mid-turn; in a Cloud workspace the next message may be somebody else's,
  so every backend waits for the turn to end.
- **Archive on the machine winds the workspace down; it does not delete anything.** The client
  asks the machine for `archive_preview`, confirms with `archive`, which checks the answer again,
  stops every turn and closes the door, and then asks runbloom.app to archive, which deletes the
  machine. A confirmation whose answer moved comes back as a fresh preview.
- **A chat that has spoken keeps its agent.** `set_composer` refuses another agent on a chat with
  messages, as the Mac does; a client opens a new chat instead.
- **Agent sign-in probes and Codex speeds are not ported.** #163's `ServerAgentAuthentication`
  asked each CLI whether it was signed in, which answers nothing when every turn brings its own
  key. It comes back with personal subscriptions signed in on the machine.
- **The review's uncommitted scope is one row per path**, measured from `HEAD`, because the wire
  record cannot tell a staged row from an unstaged one. A file over 2 MB is listed without a line
  count rather than read whole.
- **A slow reader is disconnected, never skipped.** An event stream or a terminal attachment whose
  buffer fills is closed, and the client reconnects from its cursor or redraws the screen, because
  a transcript with a gap or a terminal missing bytes looks complete and is not.
- **Cloud project settings are read from the repository's files only**, never from the machine's
  home directory, which belongs to the machine rather than to anybody's preferences.
- **The protocol schema is checked without a JSON Schema package.** `Protocol/v1/schema.py`
  validates the subset the schema uses, so the check runs in CI's lint job with nothing installed.
- **runbloom.app installs, the machine updates.** runbloom.app's bootstrap execs
  `bash -s -- <version> <sha256>` with its own script, unpacks
  `bloom-runner-linux-x86_64-<version>.tar.gz` from the `v<version>` release (its `bin/` at the
  archive's root) into `/opt/bloom/<version>`, links `/opt/bloom/current`, and creates the `bloom`
  service running `/opt/bloom/current/bin/bloom-runner serve` with no arguments, which reads
  `/etc/bloom/workspace.json`. `control/update` does not run that again: the machine installs the
  release with `bin/bootstrap-machine.sh update` and restarts its service; the start wrapper and
  runbloom.app are what undo a release that will not come up. A
  release must publish the archive and a `.sha256` beside it in `sha256sum` format, or machine
  creation fails. Control calls time out after 15 seconds on runbloom.app's side, so each answers
  before doing slow work.
- **The workspace secret rotates.** When anybody loses access to a workspace, runbloom.app
  rewrites `/etc/bloom/workspace.json` with a new secret and then calls `control/secret-rotated`;
  the old secret stays valid there for two minutes so reports in flight land. The machine takes
  only the secret from the rewritten file (one naming another workspace is ignored), and a call
  answered 401 `invalid_workspace_secret` reads the file again and is sent once more if the secret
  changed, in case the control call was missed. `revoke` takes `user_ids` as well as `user_id`.
- **In a shared workspace, git credentials during a turn are the repository's, not the
  prompter's**: runbloom.app answers an installation token scoped to the repository, and refuses
  turns from anybody without push access with 403 `no_push_access`, which the machine handles like
  any other non-limit refusal.
- **Becoming shared retires personal credentials.** runbloom.app calls `control/shared` before
  anybody new gets access. The machine answers at once, then stops every agent process and ends
  every terminal launched with a personal key or personal environment; a turn running on one ends
  with "This Cloud workspace was shared, so the turn stopped; the next turn uses the team key", and
  queued prompts stay queued. It is idempotent, and it also happens when a turn or terminal start
  answers a team key for an agent something holds a personal key for, or no personal environment
  where something holds some, in case the call was missed.
- **Revoking takes effect at once, not when tokens run out.** Tokens and preview cookies issued
  before a revoke (plus the thirty seconds of clock skew) are refused, and the list is kept in the
  database for eight hours, the longest preview cookie. The person's queued prompts are removed
  rather than left to pause the chat for everybody, their running turn stops, and the shells they
  opened end. Withdrawing a share link is a revoke too: runbloom.app sends the `share:<id>` subject
  as `user_id`, and that link's preview cookies stop working at once.
- **The local git credential route takes a turn only while it is live on the machine.** A chat's
  turn is looked up by `BLOOM_CHAT_ID`, a terminal's by `BLOOM_TERMINAL` (the turn of whichever
  connection to it is open, since a shell outlives the connection it started with), and a bare
  `turn_id` is accepted only while a push or pull request runs under it. Every shell can read the
  local secret, so a named turn is otherwise another person's push waiting to happen. **And the
  caller has to be what it names**: the route finds the calling process from its loopback port in
  `/proc`, walks up to the child Bloom Runner started, and honours a chat only under that chat's
  agent, a terminal only in a pane of the Runner's own tmux server, and a turn only under the
  publishing command started for it. A setup script, a service or another chat's agent gets a
  read-only token whatever it names (`LocalProcessTable`, M1 in the review of 19 September 2026).
  Code running as the same user can still reach into those processes or the tmux server, which
  running the agent as a second user is what ends.
- **A terminal belongs to whoever opened it.** Its shell holds that person's key, personal
  environment and turn, so nobody else attaches to it or closes it by name. Keys reach tmux through
  the creating client's environment (`update-environment`), never its arguments. A renewal of a
  terminal or an event stream checks abilities again, and the command journal is kept per person.
- **What the review accepted rather than changed.** Every terminal gets the agent keys runbloom.app
  resolves for its person, as designed; with sudo on the machine that makes a team key readable
  by anybody with the `terminal` ability. Agent to agent messages inside a workspace run on the key
  their chat already has and are not registered as turns. Setup output reaches everybody who can
  view, so a script that prints its environment prints it to them. A hard link in the worktree is
  not refused on download, because pnpm fills `node_modules` with them and planting one needs code
  execution on the machine already. The verifier refuses `crit` headers and abilities named twice;
  runbloom.app's check of `iat` against a key's activation time does not apply on the machine,
  because the published key set carries no activation time.
- **runbloom.app's refusals, as the machine treats them.** 401 `invalid_workspace_secret`, once
  the file holds no other secret, is terminal: the machine stops reporting. 429 and 5xx (including 503 `unavailable` from
  git-credentials while GitHub is down) are retried with backoff; any other 4xx drops that report.
  A turn start refused for anything but a limit pauses the chat's queue with runbloom.app's
  sentence rather than marking the prompt blocked, since that turn can never run as it is.
- **For the Mac client:** a session token answers `{data: {token, expires_at, machine_url, awake,
  abilities}}`, a preview token `{data: {token, expires_at, enter_url}}`; 409 `machine_not_ready`
  also covers a failed or not yet created machine, and 409 `workspace_archived` an archived one.
- **Linux runs the core tests the server needs, by name.** `Package.swift` lists them, so a test
  written on a Mac about the window cannot fail a Linux job its author never thought about.

### For the Mac client pull request

Taken while building the Mac client. The runbloom.app shapes were agreed with its builder through
the coordinator.

- **runbloom.app answers Laravel resources:** `{"data": ...}`, lists as `{"data": [...]}` with no
  pagination, `/me` as `{"data": {...}}`, refusals as `{"code", "message"}` plus `limit` and
  `retry_after` where they apply.
- **Sharing.** `GET /api/v1/cloud-workspaces/{id}/members` answers `{"data": {"shared_with_team",
  "members": [{"user": {"id", "name", "avatar_url"}, "role"}]}}`; `POST` the same path with
  `{"user_id"}` or `{"shared_with_team": bool}` answers the same body; `DELETE .../members/{user}`
  answers 204 and cancels that person's queued turns, ends their running ones and closes their
  streams, which the confirmation says. Owner only; 403 `no_team_agent_key` when a team key is
  missing. Collaborators are chosen from `GET /api/v1/teams/{team}/members`, `{"data": [{"id",
  "name", "email", "avatar_url", "role"}]}`.
- **Members carry `push_access`**: true, false (no push access, or GitHub not connected) or null (not
  checked, or GitHub unreachable). Only false is shown, as "Cannot push". A share's `created_by` may
  be null. A workspace the reader cannot open is listed with only `id`, `team_id`, `name`, `state`,
  `owner`, `role` (null), `can_open`, `can_archive`, `created_at` and `archived_at`, and is drawn as
  not openable, archivable when `can_archive` says so.
- **Every empty state is a title, a sentence and one button**, decided by `CloudEmptyState` and
  drawn the same way in the sidebar's section (compact), the centre column and the create sheet: a
  Mac that is not signed in says what a Cloud workspace is and offers signing in, a team in early
  access says so, a team with steps left names the first one and goes to its own page on
  runbloom.app (`setup_url`, plus `projects` or `agent-keys`), and a ready team with nothing created
  offers creating the first one. The create sheet offers the same buttons rather than grey text, and
  says in one line what is stopping Create.
- **The sidebar's Cloud section is hidden until this Mac has signed in once**, and stays after
  signing out, with the way back. Bloom needs no account, so a Mac that has never used a Cloud
  workspace is not asked to in the pane somebody looks at all day; a Mac that has is missing a sign
  in rather than being offered one.
- **Every state a first Cloud workspace passes through says what it is and what to do.**
  `CloudConnectionBanner` is the one place that decides it, and its tests name the states that must
  offer something: setting up (watch the output), setup failed (read it, run it again), asleep
  (wake), waking and getting ready (nothing, they finish by themselves), a limit that clears by
  itself (nothing) against one that does not (runbloom.app, try again), no access and reconnecting
  after a dropped network (try again). What a person is missing before they can prompt at all, a
  GitHub connection or an agent key, is said over the composer before anything is typed
  (`CloudPromptReadiness`), and a refusal from runbloom.app or a machine is shown in its own words
  with the way back to where it is settled (`CloudRefusalNotice`).
- **A team that is not ready says what is missing.** Each team in `/api/v1/me`, and
  `/api/v1/teams/{team}` itself, carries `cloud_workspaces`: `enabled`, `setup_complete`,
  `github_connected` (the signed in person's), `github_app_installed`, `has_project`,
  `has_agent_key` (team keys only) and `setup_url` (`https://runbloom.app/app/<team>`, opened as given).
  `setup_complete` is runbloom.app's own verdict and wins over counting the four here, because it
  counts steps a given version of the app may not know about. The
  create sheet and the Bloom Cloud settings pane list the steps still to take and offer "Finish setting up
  on runbloom.app", which opens `setup_url` only when it is on runbloom.app's own origin; a team not
  in early access says so. A runbloom.app that sends none of it changes nothing.
- **`sharing_in_progress`** (409, `retry_after`) on a session or preview token, for anybody but the
  owner while runbloom.app tells the machine the workspace became shared, is waited out like
  `machine_not_ready`: a short starting state, then asked again.
- **Refusals while sharing** are shown as runbloom.app words them: 422 `already_owner`, 403
  `owner_cannot_be_removed`, 404 for removing somebody who is not a member, 409 `workspace_archived`
  for any change to an archived workspace. A collaborator who left the team is still listed, so the
  owner can remove them; the Mac shows them as having left, by their absence from the team's members.
- **Preview links.** `GET .../shares` lists live ones as `{"id", "url", "created_at", "expires_at",
  "created_by"}`; `POST {}` (or `{"expires_at"}`, a week by default and a month at most) answers 201;
  `DELETE .../shares/{share}` revokes. Owner only. A link stops working when its creator can no longer
  share, and shows a "still starting" page until the machine is ready.
- **The opening prompt is the Mac's.** Create takes none. The Mac keeps it in its own defaults,
  survives a relaunch, shows it as waiting, and sends it on the first live connection as `new_chat`
  then `send`, each under a command id kept with the prompt so a retry cannot open two chats or
  queue it twice. A prompt still held after a day is dropped.
- **Where the code is.** `Packages/BloomClient` is Foundation and `BloomProtocol` only: runbloom.app's
  API, `WorkspaceConnection` (tokens, commands with kept ids, the event stream, reconnecting, not
  reconnecting after `sleeping`), `CloudWorkspaceState` (merging pages and events), the terminal
  socket, the review cache and every decision the window draws. Its tests run in the macOS `test`
  job, because the event stream is read with URLSession byte streams Linux Foundation lacks.
  `Packages/BloomAuthentication` is #163's, on AppAuth 3.0.0 with the custom scheme; the tokens are
  one keychain item per runbloom.app origin. `BLOOM_RUNBLOOM_URL`, or the
  `cloudWorkspaces.runbloomOrigin` default, points a build at a development runbloom.app.
- **A Cloud chat is a `TranscriptModel` with no store.** Its rows, queue and questions arrive from the
  machine through `receiveCloud`, and send, stop, answer, the composer's pickers, removing a queued
  prompt and marking read go to the machine through a `CloudChatLink`. So a Cloud conversation is
  drawn by the app's own transcript and composer, and nothing from a machine is written to this
  Mac's database. Its rows get negative ids, one per workspace and cursor, so no cache can confuse
  one with a local row.
- **A Cloud workspace is its own selection and its own column.** `SidebarSelection.cloud` answers
  `workspaceID` with nil, so the inspector, the Workspace menu, the terminal pane and session restore
  (all about a worktree on this Mac) leave it alone, and `CloudWorkspaceColumn` draws its chats,
  terminal, changes and setup output as panes of its own.
- **Signed out, nothing asks.** The sidebar has no Cloud section and the New menu no Cloud item until
  a Bloom account is signed in; Settings has a Bloom Cloud pane that says what an account is for.
- **The list is read every 20 seconds while Bloom is active, whenever it becomes active, and every
  minute in the background,** where its notifications matter most. Notifications are derived from consecutive readings: into `waiting_for_input`,
  `running` to `idle`, into `setup_failed`; not on the first reading, not for a workspace the reader
  has no role in, and not for the one on screen while Bloom is in front.
- **Waking.** The first request after a machine was last seen asleep gets 45 seconds before it counts
  as no answer, later ones 25; a request with no answer is retried twice under its command id. The
  column says the workspace is waking once half a second has passed.
- **The review is read when its pane is shown and on `review` events,** not by a `wait: true` long
  poll, which would hold a request open on a machine that is trying to sleep.
- **Only the workspace on screen keeps its event stream.** Leaving one suspends its stream and keeps
  its cursor, because a stream left open reconnects by itself after a dropped network, and a
  reconnect is what wakes a machine. A stream refused twice in a row with fresh tokens stops.
- **Sign in uses an ephemeral browser session,** so signing out leaves no web login behind for the
  next person, and signing out revokes both tokens, clears held opening prompts and removes Cloud
  banners. A token is only sent to an HTTPS machine address (plain HTTP only on loopback), and a
  preview only opens on its own machine's host. A machine's shell cannot write this Mac's clipboard.
- **Each person gets a terminal of their own,** named `shell-<user id>`, because a terminal is a
  turn with its opener's keys and GitHub identity. A keystroke into a closed terminal reconnects it,
  and reattaching by name answers with one frame that is clear screen, cursor home, then the pane as
  it stands, so a client feeds it as it is and never appends it to what it was showing. The shell
  behind it survives a socket that disappears with no close frame, which is a laptop closing, and
  does not survive the workspace restarting, which takes tmux with it; one closed socket looks the
  same either way, so the app says the connection stopped rather than guessing at the shell, and the
  redraw is what answers it. `reauth` swaps a token on a live socket, so a long session does not
  break when one expires. Nothing is written into the stream to mark a reconnection: the clear
  screen takes anything written there off the screen and out of the scrollback, which
  `CloudTerminalProbe` measures, and is also why there is nothing stale for a new prompt to be
  confused with.
- **Left out of the first Cloud release on the Mac:** attaching files to a Cloud chat (the composer
  says so), Steer (a shared queue is first come, first served), and handing the queue back to the
  composer on Stop, since it may hold other people's messages. Edit on a queued prompt takes back
  only the reader's own. A Cloud chat's composer never applies this Mac's defaults over the
  machine's controls.
- **Archiving always asks,** whatever the local confirmation setting: the machine's own
  `archive_preview` when it can answer, runbloom.app's last summary when it cannot, and the sentence
  that the conversation is deleted first in both.

### The preview inside Bloom

The preview opens in a Browser tab in Bloom, as a local workspace's does, and not only in the
default browser. **The cookie stays, and no per-request token replaces it.** A token on every
request would have to live in the web view's address bar or in every link the project's app writes,
where a page could read it, copy it and use it later; the cookie is the thing a browser is built to
keep out of a page's hands.

How it works: the Mac asks runbloom.app for a preview token, navigates the web view once to
`https://<machine>/_bloom/preview/enter?token=…`, and the redirect sets `__Host-bloom-preview` in
that web view's own store. Everything that made this safe from a browser still holds: the cookie is
`__Host-`, `HttpOnly`, `Secure`, `SameSite=Lax`, Caddy strips it from `Cookie` before the request
reaches the project's app, blanks a `Set-Cookie` that tries to plant one, and answers `/_bloom/*`
from Bloom Runner rather than from the app. So the preview cannot reach the control API, and the
app's own JavaScript cannot read the credential that let the tab in.

The Mac's half, agreed with its builder and written here because the safety depends on it:

- A **non-persistent `WKWebsiteDataStore` per Cloud workspace**, made when that workspace's Browser
  tab first opens and dropped when the workspace is closed or archived or the account signs out.
  Never the app's shared store, and never shared between workspaces: one store per origin means one
  workspace's preview cookie can never travel to another machine's origin, and nothing survives a
  relaunch, so the cookie's real life is the shorter of its eight hours and the window staying open.
- The web view is **navigated only to the enter URL runbloom.app has just issued**, with the token in
  that one navigation. No token is injected into a page the app did not navigate to, the address bar
  cannot be used to enter with a token, and a page that navigates off the machine's origin carries no
  Bloom token with it.

**What an attacker gets.** Somebody who reads that web view's store, which means code already
running as the person on their Mac, gets the preview of one workspace for up to eight hours: the
project's app as that person sees it, and nothing else. That is what a share link already hands out
deliberately. They do not get the control API (a preview token grants `preview` and nothing more,
and the RPC, event stream and terminal routes all refuse anything but a session token), they do not
get another workspace (the cookie is `__Host-`, bound to that machine's host, in a store that holds
only that machine), and they do not get the agent's keys or a GitHub token, which never leave the
machine.

## One UI, two kinds of workspace

The owner's instruction, after the first Cloud panes were built beside the local ones: "I really
want the UI to use the same code for local and remote, so that if I change this, it is both for
local and cloud." So there are no Cloud views of things a local workspace already has. There is one
set of views, written against protocols, with two implementations behind them.

**`WorkspaceSurface` is the first of those protocols.** It is what the inspector and the
review panes ask a workspace for: the changed files and their patches, the file tree and a file's
contents, the read ticks, the scope, the branch's commits, the pull request and the things a reader
can do to one. `WorkspaceModel` answers it out of the worktree on this Mac, `CloudWorkspaceSession`
out of the machine. It was written from what the inspector already asked `WorkspaceModel` for, and
`WorkspaceModel` conforms to it with five new members and not one changed one, which is the reason
the local path could not regress: the views call the same methods on the same object they always
did.

**Generic over the protocol, never `any WorkspaceSurface`.** SwiftUI's `@Bindable` refuses an
existential, and the inspector binds a selection and a tab. `struct FileTreeView<Model:
WorkspaceSurface>` keeps the binding and keeps every type static, so the redraw behaviour
these columns were tuned for is what it was. The cost is real and is paid in one place: a generic
SwiftUI body is much harder work for the type checker, and `FileTreeView` had to be cut into
`body`, `watched`, `loading`, `stack` and `scroller` before the CI runner would finish it. Cut a
generic view up before it is a problem rather than after.

**Differences are capabilities, not branches.** `WorkspaceCapabilities` in the core carries one
case per thing a workspace might not be able to do (revealing a file, reverting, a shell, managing
the pull request, history, transcript search, Keep Awake, a preview), and each case carries the one
sentence that says why it is off for a Cloud workspace. A view asks whether the capability is
there; it never asks which kind of workspace it has. An action that cannot work stays where it is,
greyed, with that sentence, and with the honest equivalent beside it: GitHub where a local
workspace offers the Finder, the workspace's own terminal where it offers a shell in a folder.

**And the test that catches what a capability cannot: is this a question about a workspace, or a
question about this Mac's disk?** Ask it of every question a shared view asks, one at a time, when a
view is converted. A capability is a thing a workspace cannot do, declared and answered by the
workspace; this is the other half, where a view asks something the local implementation can answer
and the Cloud one can only answer wrongly, and nothing declares it. Two bugs came out of the review
pane's conversion by asking it. `ReviewPaneView` handed `editorKey` to `FileManager.fileExists`,
which for a Cloud workspace is a synthetic `cloud:<id>/<path>` and so reported every file as gone:
a question about the disk, asked of a workspace that has none, and one that would have drawn
something slightly wrong rather than crashed and been very hard to trace back. The empty
conversation said "the setup script is still running", which is a worktree's sentence and not true
of a machine that is still cloning.

`editorKey` is the shape of the underlying fault and is worth stating on its own: it is a path for a
local workspace and an opaque key for a Cloud one, so anything treating it as a path is wrong for
half the workspaces, and nothing in the type system says so. The other reader of it in a shared view
is `AllFilesReviewView`, which hands it to `SourceEditorState.file(_:)`. That one is harmless for a
reason that can be stated rather than harmless because nothing broke: a Cloud key matches no editor
state, so the scroll falls back to the file's own anchor. Two ways to finish this. Audit the rest of
the protocol for any member whose value means one thing locally and another in the cloud, which is
the same trap wherever it appears. Better, give that key its own type, so `FileManager` will not
take one and the bug cannot be written; that is a change for after this branch merges, and it
retires the rule instead of asking everyone to hold it.

**The diff is `DiffView` on both sides.** The hunks, the expanders, the whitespace fold, the find
bar, Viewed and Discard are one view over the protocol. Three things are asked for only where they
can work, and each says so where the control would be rather than disappearing: the in-place editor
and the whole-file editor (`.editFiles`), which need the bytes on this Mac and the language servers
rooted in the worktree; notes on a diff (`.reviewComments`), which are worth sending the day the
composer slice lands; and go to definition, which needs the same language server. The editor pane
is built by the workspace rather than by the diff, which is the one place a view is handed back
from a model: `WorkspaceModel.editorPane(path:session:)` answers with the editor and a Cloud
**And the pane around the diff is `ReviewPaneView`, arrangement included.** All files against
Selected file, the pinned tab that stays on the file it was opened with, the continuous review with
its collapsible per-file headers, and the composer under it that sends what you read to a chosen
chat, are one view over the protocol for both kinds. This was the last place a person could feel
which kind of workspace they were in: a Cloud review used to be a list beside a diff and nothing
else. One question in it really is the worktree's, and is asked as one: whether the file is still on
disk. `FileManager.fileExists` is run only where there is a worktree to run it against, because a
Cloud path resolves to nothing on this Mac and the pane would say a file that is perfectly present
on the machine is gone. What a Cloud workspace does with a file that has gone is what the machine
answers when asked for it.

**The chat is `ChatPaneView`, the same view a local conversation is drawn with.** The transcript,
the composer, the jump pill, the dock, the text size, the font and the line height are one view
over `WorkspaceSurface`. Three things differ and each is asked of the workspace rather than
branched on: where the reader had got to in a conversation (a local one keeps it on the model, a
Cloud one on its session, so both survive switching tab); what the composer needs a worktree for,
which is attaching a file, the project's quick prompts and its run scripts, and which a Cloud chat
offers the way Ask Bloom does, having no worktree either; and what hangs over the conversation,
which for a local workspace is the side conversation card and the pill back to the chat it was
opened from, and for a Cloud workspace is nothing, because a side conversation is a second agent in
the same worktree. A sentence above the composer says what runbloom.app would refuse a turn for
before anybody types it.

**And a Cloud workspace is started in the same window a local one is.** It was a modal sheet with a
four row form in it, Project, Name, Branch, From, and a First message box under them, which asks
somebody to fill in a record; the local window asks what you want to work on and derives the record
from it. The owner put the two side by side and that was the whole of his verdict. So the Cloud one
is `CreateWorkspaceView`'s window: the same band across the top, the same `Start with`, the same
question, the same composer with its own controls and Create inside it, and the same closing
sentence with one more under it, because a machine has to be made and set up before a first message
can go and a worktree does not. The name and the branch are derived from the first line of the task
rather than demanded, by the rule the local namer falls back to when no model answers. Three things
are left out rather than greyed: `Open existing branch…`, because runbloom.app creates from a base
branch and nothing else; the other two `Start with` segments, because a machine has no browser tab
of this Mac's and its terminal is a tab of the workspace itself; and a branch menu, because a
project answers with its default branch and no list, so the base is a chip with a field behind it.

**What a first turn runs with is the machine's answer, and this Mac's only until there is one.** A
client could not learn what a chat would open with until a chat existed: `new_chat` demands
controls, and `composer` needed a `chat_id`. Runner `test.9` answers both, with `composer_defaults`
on the workspace snapshot and a `composer` that takes no chat id, and the machine's answer is the
better one because it has read the repository's own `.bloom/settings.toml` and clamped to the agents
installed in its image, neither of which a client can see. **It belongs to the workspace and not to
a chat.** This Mac keys composer state by chat id, and a reply with no chat id under a synthesised
key would collide with a real chat the day the machine shortens its ids, which would show somebody
another chat's settings and is the sort of bug nobody goes looking for. So it is a property of
`CloudWorkspaceState` beside the chats rather than a row among them.

The create window is the one place that cannot ask, because no machine exists while it is open. So
it shows this Mac's choice, and **only a deliberate change is carried**: `PendingOpeningPrompt`
holds nil for "whatever the machine would open with", and the first turn is opened with the
machine's own defaults a couple of minutes later. A value nobody touched gives way to the better
answer; a value somebody picked does not. New Chat in a workspace that already exists takes the
chat in front's controls, and the machine's defaults when there is no chat in front.

And the local choice stays as the fallback rather than being retired: a machine on an older runner
answers without defaults for as long as such a machine exists. The snapshot's field is required in
the schema and optional in what this client accepts, which is the asymmetry a client owes a server:
a machine made before the field existed and not yet updated would otherwise not be openable at all,
rather than merely missing a default.

**`available_agents` is a fact about one machine at one moment.** Two machines created from the same
release thirty seconds apart answered with different lists, which is being looked at and is not the
client's to explain. What follows from it either way is that this list is never cached across
workspaces and never drawn as the agents Bloom supports: it is what that machine can run, asked of
that machine, and it is allowed to differ from the machine beside it.

The protocol is `WorkspaceSurface` now rather than `WorkspaceReviewSurface`: it stopped being about
the review the moment the band, the checks and the chat were written against it.

**Setup is part of the conversation, in both kinds of workspace.** It had a tab of its own here for
one day, on the argument that it is the one thing a Cloud workspace has and a local one does not.
The owner put the two side by side and settled it: locally the setup output is a row at the head of
the transcript, where the reader already is, and a tab only one kind of workspace has is exactly the
feeling this whole section exists to remove. So the machine's setup goes through the same
`WorkspaceEvent` the local one does, drawn by the same row, in the same place in the reading order,
with the same disclosure over the log and the same Run setup again beside a failure. What the
machine knows and a worktree does not is used inside that row rather than as a reason to keep a
pane: the named step while it runs, and the last lines of a failure without asking for the whole
log. The banner that offered to show the tab went with it, and `CenterTabKind.setup` stays only so
that a tab list written while the tab existed still decodes; the store drops those tabs on the way
in.

**A Cloud workspace has no header bar of its own.** Its name is the window's title, its branch and
its pull request are the title bar's band (`PullRequestBar`, over the protocol), and its `+` is the
toolbar's, exactly as a local workspace's are. A bar above the tabs saying all three again was the
largest thing that made a Cloud workspace feel like a different app. What is left is what a local
workspace has no answer to, and it sits in the toolbar: who else has the workspace open, the
preview, and sharing.

The band draws what runbloom.app read from GitHub with its own App: the state, the checks rollup,
the merge blockers, the review decision and whether this person may merge. The machine's own `gh`
answer is the fallback for the moment before runbloom.app has replied, because it arrives with the
workspace rather than on a request of its own. Merge and Mark ready for review go to runbloom.app
and happen as the signed-in person, with the head commit sent so a branch that moved under the
reader is refused rather than merged on trust; `can_merge` is what greys the control, so somebody
without push access sees why rather than a failure after pressing. Open a pull request, Commit and
push and Fix conflicts compose a turn for the agent and work as they do locally. The Checks tab is
the local one, over the same list.

**That state is cached and up to a minute old, and the app says so rather than implying it is
live.** runbloom.app refreshes on a schedule, every body carries `fetched_at` and `stale`, and
`CloudChecksWording.freshness` turns those into the line under the checks. Nothing polls harder in
the hope of something fresher. Two shapes to know about: `mergeable` is genuinely three-valued,
because GitHub answers null while it is still working it out, and null is "not known yet" rather
than "no"; and the same count is `passed` in the pull request body and `succeeded` in the checks
body, which is a wart of runbloom.app's and is read in one place here rather than papered over.

**A machine's own runner restarts under an open window, and the client is tuned for it rather than
against it.** A sleeping workspace updates itself the moment it wakes and goes idle, which is
seconds after somebody opens it, and the process is gone for about eight seconds on the good path.
Three things follow. A dropped connection says nothing for two seconds, so a drop that mends itself
never raises a banner, and the reconnection attempts land at 0.5, 1, 2, 3 and 5 seconds before
backing off to half a minute, so the common case is covered four times over. A command keeps trying
for thirty seconds rather than five: three attempts a second apart gave up before the machine came
back, which meant a prompt sent in that window was guaranteed to fail in front of the person for no
reason. Retries go under one command id, so a machine that took the command before it died answers
the retry from its journal. And a stream that resumes from a cursor the machine can no longer
replay from answers `skipped`, which now makes every open chat read its history again rather than
leaving the rows in the gap missing for the life of the window.

**A machine that put itself back says so.** A Cloud workspace's machine updates itself, and when a
new version will not start it restores the previous one. runbloom.app reports that as
`runner_notice` on the workspace, in three kinds: being rolled back, rolled back, and the update
failed. The first is drawn as progress and cannot be put away, because it ends by itself and is
replaced by its outcome; the other two rest, and are dismissed on the same rule as a failed setup.
The sentence is runbloom.app's own and is drawn as it stands, because it names versions this Mac
does not know. A workspace quietly running an older version than anybody thinks is what produces a
bug report nobody can reproduce.

**A machine that cannot reach runbloom.app says so too, and this one is not drawn yet.** The
workspace record carries `reporting` when something is wrong and leaves it out when nothing is, with
`unreachable_since` and `shed`. `unreachable_since` is the moment of the last report that got
through rather than the moment the first one failed, because an outage that began while nothing was
being sent still began then, and it clears on the first success, so a flap does not read as an
unending outage. `shed` appears once the queue has hit its four megabyte cap and started dropping
its oldest entries, which is a fortnight of a quiet machine or about a day and a half of a busy one.

The whole job here is the sentence, and it is about the record rather than about the work: the
turns are still running and still saved, what they cost is not being recorded at the moment, and
after the cap some of that account is gone for good. Anything that reads as "your work is being
lost" is wrong and will frighten somebody for no reason. It belongs in `Packages/BloomClient` beside
the other notices so that the web client inherits it rather than inventing a second story, and it is
a banner rather than anything smaller, one that cannot be put away while it is true, because unlike
a rollback it does not end by itself. Until it is built, a client that does not know the field
ignores it: `CloudWorkspaceItem` decodes from a keyed container, so a key it has never heard of
changes nothing.

**History is the machine's own `git log`.** `history` pages the branch's commits and `commit_files`
answers the files of the row somebody opened, so the History tab draws the rows it has always drawn.
Two differences from a local workspace, both said where they matter: Load earlier commits pages from
the oldest row rather than asking again with a larger limit, because a machine is across a network
and may be asleep; and a commit's diff is `commit_patch`, its own operation rather than a third scope, because a sha
in a scope would have to mean something for `review_snapshot` too. It is cached per commit for the
life of the workspace, since a commit cannot change. A machine too old to know the operation
refuses it as an invalid request, and that one refusal becomes the sentence saying the workspace
has to be updated; every other refusal is the machine's own words, because "this file did not
change in that commit" is something a reader can act on.

**What is still a Cloud view of its own, and what each one is waiting for.** The tab strip is the
next and the largest: `SessionTabsView` is written against `WorkspaceTabsStore` and `CenterTabStore`
for its splits, its drag between panes and its ordering, and a Cloud workspace has none of those
stores. Two ways out were weighed. Making the strip generic over `WorkspaceSurface` means another
fifteen members on the protocol, several of them meaningless in the cloud (absorbing a tab,
duplicating a pane). Keying the two stores by `WorkspaceSurfaceID` instead, so a Cloud workspace's
tabs are ordinary rows in them, would give the strip, the panes, the splits and the `+` menu to
both with no view changing at all, and would retire `CloudTabs`. The second is the better shape and
the riskier change, and the risk is all on the local side, which is the side that must not regress.
Take it with the stores' own tests in front of you rather than in passing.

After that, in the order they are worth doing: the sidebar's Cloud column (its row already wears
the column's own mark), the create and archive sheets and the empty state. The menus and the tab
commands are done: New Chat, New Terminal Tab, Show Changes, Rename Tab and Close Tab act on a
Cloud workspace on the same keys, and what a machine has no answer to is left out rather than
faked. **Two things are deliberately not on that list, and this is why rather than an oversight.** The
terminal pane and the share popover stay their own views. A local terminal is a process on this Mac
that SwiftTerm drives directly; a Cloud one is a byte stream over a WebSocket that reconnects and
redraws, with its own attach frame and its own name per person, so there is no local behaviour for
it to converge on, only a shared look it already has. A share popover is a public link to a preview
running on a machine, with people from a team on it: a local workspace has no such object at all,
so a merged view would be one kind's view with the other kind's half greyed out for ever. If a
later reader finds these two inconsistent with everything above, this paragraph is the answer:
they were looked at and left alone on purpose.

The slices, in the order they are being built: the review surface (this one), then the tab strip,
header and banners, then the composer and transcript behind a chat backend, then the terminal and
the browser tab, then the sidebar rows, menus and archiving. Each one leaves the app working, and
each one reports what changed in the local path and how that was checked.

## When a Cloud workspace misbehaves

The first people to use this will be reading a workspace that is stuck without knowing which half
is at fault, so here is what each thing means and how to tell the two apart.

**The one word on a workspace** is `RemoteSummary.state`, worked out from setup and the chats, in
this order: `setting_up` while setup is pending or running, then `waiting_for_input` when any chat
has a question nobody has answered, `stopping` while a stop is going through, `running` while a turn
is running, `blocked` when a team limit is holding a prompt, `setup_failed` only when setup failed
and nothing has happened since, and `idle` otherwise. A chat carries the same words for itself. A
workspace that says `running` long after the agent went quiet is a bug worth reporting: the machine
sends a fresh summary a moment after a chat goes idle.

**A machine stuck in setup answers everything you ask it except the one thing that matters.** This
was measured, not imagined. On one fresh Sprite the first subprocess of the server's life, a
`git config` run before any setup step exists, spawned a child that exited within a second, was
never reaped, and `Process.run()` never returned. For eighteen minutes that machine answered
`/_bloom/health`, served RPC, held a summary saying `setting_up`, and when the service was finally
restarted wound down cleanly in eighteen milliseconds. The workspace was never cloned and nothing
anywhere said so. So **health, RPC and a summary are not evidence that a machine is working**, and
two things now exist because of it.

- **A launch that never returns is abandoned.** `Shell.run(timeout:)` used to cover only the reading
  loop; the launch before it had no deadline of ours. It now gets the caller's timeout plus fifteen
  seconds, after which the worker thread is left where it is and the call fails.
  `Shell.abandonedLaunchCount` counts those, because one is a fluke and fifty is a machine to
  replace rather than to keep restarting.
- **Setup says when it has stopped moving.** Every five minutes a step goes with no output and no
  change, the machine writes a line into the setup log a person is watching, and into the service
  log. Output counts as progress, so an hour-long `setup` script that is printing is never called a
  stall. It says so and does nothing else: restarting the machine's server clears that hang, and
  the side that should act on it is runbloom.app, which can see a machine from outside.

**No debugger will ever attach to a hung Bloom Runner on this provider.** `gdb` installs on a Sprite
and then fails with `ptrace: Inappropriate ioctl for device`; there is no `kernel.yama.ptrace_scope`
to relax, because the sandbox does not implement `ptrace` at all, and `/proc/<pid>/syscall` is empty
for the same reason. What is left is `/proc/<pid>/task/*/wchan`, the kernel stacks under
`/proc/<pid>/task/*/stack` as root, and the process table. Do not spend an hour finding this out:
**what the machine says about itself is the only forensics there will ever be**, which is the whole
argument for the watchdog above.

**A project with no Cloud workspace setup is told so before anything runs.** A repository with no
`.bloom` settings file and no `prepare`, `resume` or `[[services]]` has nothing written for a
machine, so the setup log opens with what to add and a warning that the project's existing setup
script, which may have been written for a Mac, runs as it is. Setup is still attempted: refusing
would leave somebody with a workspace that does nothing.

**Every script gets the same variables as on a Mac**, under both the `BLOOM_` and `CONDUCTOR_`
prefixes: `IS_LOCAL` (`0` here), `WORKSPACE_NAME`, `WORKSPACE_ID`, `WORKSPACE_PATH`, `ROOT_PATH`,
`PROJECT_NAME`, `DEFAULT_BRANCH` and `PORT`, beside the machine's own `BLOOM_PUBLIC_URL`,
`BLOOM_PUBLIC_HOST`, `BLOOM_APP_PORT`, `BLOOM_BRANCH`, `BLOOM_REPOSITORY`, `BLOOM_DATA_DIR` and
`BLOOM_RUNNER_PORT`. `WORKSPACE_PATH` and `ROOT_PATH` are the same path, because the clone is both.
This is not tidiness: scripts in the wild start with `set -u` and read `$BLOOM_ROOT_PATH`, and an
unbound variable ends them on their first line with nothing a person can act on.

**Setup output** goes to two places, and the row is the one a person reads. Every step appends to
the workspace's setup log, a few writes a second, which clients watch through the event stream; the
log is capped, so a very long `apt` or `composer install` keeps its tail rather than its head. The
whole of each step is also kept on the machine under `~/.bloom/setup/<step>.log`, up to 20 MB, which
is where to look when the row has been trimmed. A run the machine was stopped in the middle of is
added to rather than started over, so an interrupted first attempt stays visible above the second.

**A failed step names itself**: "The setup script exited with status 4.", and the last lines of a
failed run travel with the workspace record (`setup.note`), so a client can say what went wrong
without asking for the whole log.

**A failed setup does not cost the workspace.** Prompts go once setup ends, however it ended, so a
failed `setup` script leaves a workspace somebody can still work in; the log says what failed, and
`run_setup` runs it again. A clone that fails says what to check (the repository still exists, and
Bloom's GitHub App is installed for it) rather than leaving git's own message alone.

**A preview that shows nothing** is answered by Bloom Runner rather than by Caddy, and names the
project's services and how each ended: `vite: crashed after 3 restarts. Exited with status 1.` A
service that keeps crashing is restarted with a growing wait, so this page is the quickest way to
tell "the app never started" from "the app is slow".

**A release that will not start is undone at the next start, not by the script that asked for it.**
`sprite-env services restart bloom` ends the script that called it, so the loop in
`bootstrap-machine.sh` that was meant to watch the health check never runs during a real update.
Measured on a Sprite: a service whose process exits at once is restarted for ever, about once a
minute (`restart_count` 1, 2, 8, 12 over seven minutes). So `bin/bloom-runner` in the package is a
small start wrapper, with the binary beside it as `bin/bloom-runner-exec`, and the service's command
is unchanged. Before it execs, a `serve` reads `/var/tmp/bloom-update-pending`: the second start
that still finds the version it names current puts `current` back to the version before it. One
start is not a failure, because a machine can restart for its own reasons; and a rollback that
cannot be done (the old release gone, the symlink unwritable) execs the new version anyway, because
a machine answering wrongly can be looked at and a machine answering nothing cannot. Rolling back
from outside, through the provider, is runbloom.app's half and covers a machine that is wedged for
reasons no script on it could see.

**`/var/tmp/bloom-update-pending` is a contract, not a scratch file.** `bootstrap-machine.sh update`
writes three lines before it restarts the service: the version asked for, the version to go back to
(a bare version; older bootstraps wrote an absolute path and readers still take one), and how many
starts have seen it. The start wrapper counts those starts, and runbloom.app reads the same file in
the exec it makes when it reaches into a machine that has not healed, so a bad night reads as "19
starts on 0.2.0, going back to 0.1.9" rather than as silence. A runner that gets as far as listening
deletes it, so its absence is the normal case. Nothing read from it decides whether to roll back: it
is the account of a machine that is failing, evidence for a person rather than an input. Change the
shape and two readers change with it.

**The four review scopes.** `branch` is the merge base to the worktree, which is what the inspector
shows; `uncommitted` is HEAD to the worktree, staged and unstaged together, which is what a person
reads before committing; `staged` is HEAD to the index, what a commit would take; `unstaged` is the
index to the worktree, what it would leave behind. Files git has never seen belong to `unstaged`
and never to `staged`, because they are in neither the index nor a commit. A file read in `staged`
or `unstaged` carries that layer.

**Reverting a file and discarding a hunk work in all four, and mean what git means in each.** In
`branch` and `uncommitted` the change goes back to the baseline being compared against. In `staged`
it is `git restore --staged`, so the change leaves the index and the worktree keeps it: nothing
anybody wrote is destroyed, and the client says Unstage rather than Discard. In `unstaged` it is
`git restore`, throwing the worktree's copy away, which is the only thing the word can mean there
and the only one of the four where work is lost. A person who knows git is not surprised and a
person who does not is not robbed, which is why the two ordinary git meanings were taken rather
than one invented meaning covering both. `HunkDiscard.Intent` is where that choice lives in the
code, rather than in a comment, because the word on the button has to follow it.

**A rollback says so twice:** to the service's log, which the provider keeps at
`/.sprite/logs/services/bloom.log` with a timestamp per line, and by appending to
`/var/tmp/bloom-update.log`, which outlives the marker and any rotation. The marker only ever
describes the attempt in hand, so the second one is what lets a machine say it has rolled back twice
this week. (There is no `sprite-env services logs` subcommand; the log is a file.)

**Telling a provider outage from a Bloom Runner problem.** They look different from the app:

- The machine's URL not answering at all, or answering a provider error page, is the provider or a
  machine that is asleep and waking. Bloom Runner's own answers always carry a `bloom-runner`
  server name, and `/_bloom/health` answers with the version and nothing else.
- Everything except the preview working, or the other way round, is Bloom Runner: one process
  serves both, behind one Caddy.
- The whole team's workspaces failing at once is runbloom.app or the provider. One workspace
  failing while another is fine is that machine.
- A workspace that never leaves `setting_up`, with a setup log that has not grown in minutes, is
  a step that is genuinely running (watch the step's log on the machine) rather than a lost machine.
- Creating, waking or deleting machines failing, while existing machines answer, is the provider's
  API. It has hung for tens of minutes in testing while the status page said all was well, so a
  first reaction of "try again in a while" is usually right.
- `Tools/machine-test.py --from-release <tag>` reproduces the whole path on a throwaway machine of
  your own, and it prints which step it got to. If that passes while a real workspace does not, the
  problem is runbloom.app's side of the contract rather than the runner.

**What the machine keeps for you**, all under the data directory (`~/.bloom` on a machine):
`bloom.sqlite` with the transcript and queue, `setup/` with the step logs, `services/` with a log
per project service, `caddy/access.log`, and `/var/tmp/bloom-update.log` for the last update. None
of them holds a key or a token.

## Still open

- Nothing. The contract matches runbloom.app pull request #23.

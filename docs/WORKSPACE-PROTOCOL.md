# The bloom-workspace protocol, version 1

How a client talks to a Cloud workspace: the Mac app, the iOS app later, and a web interface in
runbloom.app after that. A client in any language can be written from this page, the
[JSON Schema](../Protocol/v1/workspace-v1.schema.json) and the
[vectors](../Protocol/v1/vectors.json). Why the protocol has the shape it has is in
[REMOTE-WORKSPACES.md](REMOTE-WORKSPACES.md); this page says what it is.

The Swift types in `Packages/BloomProtocol` are the source. `WireVectorTests` fails when they stop
encoding to the checked-in vectors, and `python3 Protocol/v1/schema.py --check` fails when the
schema stops describing them or stops listing a kind they decode. Both run in CI.

**A client decodes what a machine sends permissively; the schema is what holds the machine.** Every
field added here arrives on the machines before it arrives on all of them: a Cloud workspace updates
when runbloom.app tells it to, and one that has been asleep for a fortnight is still running the
release it went to sleep on. So a client that refuses to decode a snapshot because a field it did
not have last month is missing has turned an absent default into an unopenable workspace, which is
a far worse failure than the one it was avoiding. **Treat an added field as optional when reading,
whatever the Swift type says, and do without it when it is not there.**

Nothing is loosened on the other side by that. The schema lists the field as required, the checked
vectors carry it, and `Tools/machine-test.py` reads it off a real machine on every run and fails by
name when it is absent, so a machine that stops sending one is caught by three things that are not a
client's decoder. Strict about what a machine must send, forgiving about what an older one did not.

One thing a client reads that the schema cannot describe is the inside of a transcript row.
`message.payload` is opaque to this protocol and is **always a Claude Code `stream-json` line**,
whatever agent ran the turn: Codex and Grok are translated into that shape before a row is written,
so one renderer draws all three. [stored-payloads.json](../Protocol/v1/stored-payloads.json) is a
real Codex turn and a real Grok turn after that translation, written out of the translators
themselves, and `StoredPayloadVectorTests` fails when they stop producing it.

## Where a client finds a workspace

A client never finds a machine by itself. It signs in to runbloom.app, lists Cloud workspaces there
(`GET /api/v1/teams/{team}/cloud-workspaces`, which never wakes a machine), and asks for a session
token for the one it opens (`POST /api/v1/cloud-workspaces/{id}/session-token`). The answer carries
the token, its expiry, the machine's URL and whether the machine was awake when last seen.

Everything below is on that URL.

| Path | What | Token |
| --- | --- | --- |
| `POST /_bloom/v1/rpc` | one command, one reply | session, in `Authorization` |
| `GET /_bloom/v1/events` | server-sent events | session, in `Authorization` |
| `POST /_bloom/v1/streams/{id}/token` | a fresh token for an open event stream | session, in `Authorization` |
| `GET /_bloom/v1/terminal?name=` | a terminal over WebSocket | session, in the first frame |
| `GET /_bloom/preview/enter?token=` | enter the preview | preview, single use |
| `POST /_bloom/v1/control/*` | runbloom.app only | control |
| `GET /_bloom/health` | `{"version": "..."}` | none |
| anything else | the project's own app, once the preview cookie is set | preview cookie |

## Tokens

Tokens are EdDSA JWTs runbloom.app signs and the machine checks offline. A client treats them as
opaque strings with an expiry. What a client has to know:

- A **session token** lives five minutes. Ask runbloom.app for a new one before the old one runs
  out, and hand it to every open stream (below). Its abilities decide what a command may do: `view`
  for everything, `prompt` for sending, stopping, answering and changing chats, `files` for writing
  files, committing, pushing and running setup, `terminal` for terminals and run scripts, `share`
  for archiving.
- A **preview token** lives sixty seconds and works once. Ask runbloom.app for it
  (`POST /api/v1/cloud-workspaces/{id}/preview-token`) at the moment the preview is opened, and
  open `https://<machine>/_bloom/preview/enter?token=<token>` top level. The machine sets an
  HttpOnly cookie for its own host and redirects to `/`.
- Never put a session token in a URL. Logs and history keep URLs.

A request whose token is missing, expired, for another workspace or of the wrong kind is refused
with HTTP 401 and a failure body (below). One without the ability an operation needs gets a reply
with `missing_ability`.

## Encoding

- JSON, UTF-8, every field named, `snake_case` keys.
- Dates are ISO 8601 strings in UTC, like `2026-09-17T09:40:02.500Z`. Accept whole seconds too.
- Bytes (`upload_file`, `download`) are standard base64 strings.
- Ids are strings. Treat them as opaque; do not parse them.
- A tagged value is an object with a `kind`. An **operation** has its fields beside the `kind`. A
  **result** or **event** that carries a whole record puts it under a key named after the kind:
  `{"kind": "transcript", "transcript": {...}}`. A transcript row has a `kind` of its own, which is
  why records are never spread beside the tag.
- An unknown field in a reply or an event is ignored. An unknown `kind` in an event is ignored. An
  unknown operation is refused by the server.
- Optional fields may be absent or `null`; treat both as "none".

## Commands

```http
POST /_bloom/v1/rpc
Authorization: Bearer <session token>
Content-Type: application/json

{"protocol": "bloom-workspace", "version": 1, "command_id": "5b0e...", "operation": {"kind": "send", "chat_id": "...", "text": "Run the tests"}}
```

The reply is HTTP 200 whether the command succeeded or was refused, because the reply is what a
client records against its command id:

```json
{"version": 1, "command_id": "5b0e...", "result": {"kind": "queued", "prompt_id": "..."}}
{"version": 1, "command_id": "5b0e...", "error": {"code": "busy", "message": "Stop the current turn before changing its settings."}}
```

HTTP errors are only for what happens before there is a command: 401 for the token, 400
`invalid_request` for a body that is not an envelope, 413 for a body over 12 MB. Their body is the
failure object on its own, `{"code": ..., "message": ...}`.

### Operations

Reading (ability `view`):

| Kind | Fields | Result |
| --- | --- | --- |
| `workspace` | | `workspace`: the workspace, its chats, who is present, the newest transcript `cursor`, and `composer_defaults` |
| `transcript` | `chat_id`, `after_seq` (-1 for the start), `limit` (at most 500) | `transcript`: rows after `after_seq`, `has_more`, questions, `busy`, `streaming_text`, the queue |
| `composer` | `chat_id`, or none for a chat that does not exist yet | `composer`: its controls, the agents installed on the machine, models, slash commands, output styles |
| `setup_output` | | `setup_output`: setup's state and the whole log so far |
| `files` | | `files`: every path git tracks or would track |
| `file` | `path` | `file`: text and `revision` |
| `download` | `path` | `download`: bytes, up to 8 MB |
| `review_snapshot` | `scope` (`branch`, `uncommitted`, `staged` or `unstaged`), `known_revision`, `wait` | `review_snapshot`: `revision`, and `files` unless you already had that revision |
| `review_patch` | `path`, `scope`, `known_revision` | `review_patch`: `revision`, and `patch` unless you already had it |
| `run_scripts` | | `run_scripts` |
| `history` | `limit`, `before` | `history`: `commits` (newest first, each with `pushed` when the branch has a remote) and `has_more` |
| `commit_files` | `sha` | `commit_files`: that commit's own changed files |
| `commit_patch` | `sha`, `path` | `review_patch`: the file's diff inside that commit, refused when the commit or the file is not in it |
| `transcript_search` | `query`, `limit` | `search`: `matches` (chat, seq, cursor, and the excerpt with its matching pieces marked) and `total` |
| `notes` | | `text` |
| `pull_request` | | `text`: its URL, or empty |
| `archive_preview` (`share`) | | `archive_preview` |

Changing chats (ability `prompt`):

| Kind | Fields | Result |
| --- | --- | --- |
| `new_chat` | `controls` | `chat` |
| `rename_chat` | `chat_id`, `title` | `accepted` |
| `close_chat` | `chat_id` | `accepted` |
| `mark_read` | `chat_id`, `seq` | `accepted` |
| `set_composer` | `chat_id`, `controls` | `accepted` |
| `send` | `chat_id`, `text` | `queued` with the prompt's id |
| `cancel_queued` | `chat_id`, `prompt_id` | `accepted` |
| `stop` | `chat_id` | `accepted` |
| `answer` | `chat_id`, `request_id`, `answer` | `accepted` |

An `answer` is one of `allow_once`, `allow_session`, `allow_project`, `deny` (with `message` and
`ends_turn`), `approve_plan` (with `permission_mode`) and `question` (with `input`, the agent's own
answer shape).

Changing the worktree (ability `files`, except where noted):

| Kind | Fields | Result |
| --- | --- | --- |
| `write_file` | `path`, `text`, `revision` | `file` with the new revision, or `conflict` |
| `upload_file` | `name`, `data` | `text`: the path it was saved at, under `.bloom/attachments/` |
| `commit` | `message` | `accepted` |
| `push` | | `accepted` |
| `create_pull_request` | `title`, `body`, `draft` | `text`: the pull request's URL |
| `save_notes` | `text` | `accepted` |
| `revert_file` | `path`, `scope` | `accepted`: the file goes back, in the sense that scope has |
| `discard_hunk` | `path`, `scope`, `patch` | `accepted`, or a conflict when that hunk is no longer what the file holds |
| `rename_workspace` | `name` | `accepted` |
| `run_setup` | | `accepted` once setup has run again. Sent for a workspace with `setup.enabled` false too: the person is asking for it by hand, which is the whole point of the key |
| `run_script` (`terminal`) | `id` | `terminal`: the terminal it runs in |
| `close_terminal` (`terminal`) | `name` | `accepted` |
| `archive` (`share`) | `confirmation_id` | `accepted`, or a fresh `archive_preview` when the answer moved |

`push` and `create_pull_request` act as the person who sent them: the machine registers a short turn
under their token for the one command, so GitHub sees them rather than the machine.

**What `revert_file` and `discard_hunk` do is the scope's, and both meanings are git's own**, so a
client has to label the control with the one that matches. In `branch` and `uncommitted` the change
goes back to the baseline the reader is comparing against. In `staged` it is `git restore --staged`:
the change leaves the index, the worktree keeps it, and nothing anybody wrote is destroyed, so the
button says Unstage. In `unstaged` it is `git restore`, throwing the worktree's copy away, which is
the only thing it can mean there and the only one of the four scopes where work is actually lost.
A file is looked up in the scope's own list, so a file staged and then put back in the worktree is
reachable in `staged` and in no other scope.

### Failure codes

| Code | Meaning |
| --- | --- |
| `invalid_request` | not a version 1 envelope, or an operation's fields are wrong |
| `unsupported_version` | another protocol or version |
| `unauthenticated` | no token, a bad one, or access was removed |
| `token_expired` | the token ran out |
| `missing_ability` | the token does not allow this |
| `not_found` | a chat, prompt, file or stream that is not there |
| `conflict` | a revision check failed; read again, then retry |
| `command_id_reused` | the same command id with a different operation |
| `outcome_unknown` | the server stopped in the middle of this command |
| `busy` | the chat is running or stopping a turn |
| `workspace_changing` | the workspace is being archived |
| `already_answered` | somebody answered that question first |
| `invalid_value` | a value this operation does not take; the message says which |
| `too_large` | a body, file or prompt over its limit |
| `agent_unavailable` | that agent is not installed on the machine |
| `git_failed` | git or GitHub refused; the message is what it said |
| `limit_reached` | a team limit stopped this |
| `unavailable` | the server is shutting down or going to sleep |
| `internal` | anything else; the message says what |

A code a client does not know is treated as `internal`.

## Events

```http
GET /_bloom/v1/events
Authorization: Bearer <session token>
Last-Event-ID: 1843
```

The answer is `text/event-stream` with a `Bloom-Stream-ID` header. Read it with `fetch` and a
stream reader, not `EventSource`, which cannot send the header. Each event is:

```text
event: message
id: 1843
data: {"kind":"message","message":{...}}

```

`data` is always one line of JSON. `id` is set on `message` events only, and is the row's `cursor`.
Lines starting with `:` are keep-alives; ignore them.

When a stream opens, the server sends the current state whole: `workspace`, `setup`, then for every
chat `chat`, `queue`, `questions` and, when a turn is streaming, `stream` with `snapshot: true`, then
`presence`. Then, when `Last-Event-ID` was sent, every transcript row after that cursor as `message`
events. Then live events as they happen.

| Kind | Carries | A client |
| --- | --- | --- |
| `message` | a transcript row | adds it to its chat, by `seq` |
| `stream` | `chat_id`, `text`, `snapshot` | replaces the chat's streaming text when `snapshot` is true, appends otherwise |
| `chat` | a chat | replaces its copy |
| `queue` | a chat's queued prompts and why it is paused | replaces its copy |
| `questions` | a chat's waiting questions | replaces its copy |
| `composer` | a chat's controls and `changed_by` | replaces its copy, and may say who changed it |
| `setup` | setup's state and step | replaces its copy |
| `setup_output` | new output | appends it to the log |
| `review` | a revision number | **no machine sends this today**; see below |
| `pane_requested` | a `url` the agent named, or none for this workspace's own address, and the `chat_id` it is speaking for | **open a browser pane, if you want to**; see below |
| `presence` | who has the workspace open | replaces its copy |
| `workspace` | name, branch, pull request, `reporting` | replaces its copy |
| `sleeping` | nothing | see "Sleeping and waking" |
| `closing` | a failure | the stream ends; act on the code |

**`pane_requested` is an agent on the machine asking, not telling.** It cannot open a pane: a pane
belongs to the window of whoever is looking, and the machine is not there. So a client shows one if
it wants to, and may ignore it. **Several clients may receive the same request**, and there is no
"the" window, so each decides for itself. No `url` means this workspace's own public address, which
a client connected to it already knows. The tool that sends it tells the agent how many clients were
told, and tells it plainly when there were none, so **an agent is never in a position to report
opening something that did not open**.

**Knowing when the diff changed is the waiting `review_snapshot` call, not the `review` event.**
Ask with the `revision` you hold and `wait` true: the machine answers at once with a new `revision`
and `files` when the diff has moved, and after about fifteen seconds with the same `revision` and no
`files` when it has not, which is the signal to ask again. **The `review` event is declared in this
protocol and no machine has ever sent one.** Nothing constructs it: the case and its decoder are the
only two places it appears in the whole of Bloom. Its `revision` is also an integer where the
snapshot's is a string, because the snapshot's is a digest of the changed files and the base, so
even if it did arrive the two could not be compared. **A client that refreshes on it is writing a
path that never runs**, which one has already done. It is listed here because it exists on the wire
and a strict decoder has to tolerate it; it is not a mechanism to build on.

**The workspace record carries the project's services, and a client should draw them.** One entry
per `[[services]]` the repository declares, each with its `state` (`waiting`, `starting`, `running`,
`not_ready`, `crashed`, `stopped`), how many times it has restarted, and a sentence for a person.
**The state worth drawing loudest is `waiting`**: the machine starts a service only once everything
in its `depends_on` is ready, so one whose dependency never comes up is never launched, never fails
and never restarts, and before this record its only account was a sentence on the preview's own
error page, which a project running its own proxy on the previewed port makes unreachable. The list
is empty for a project that declares no services, and `workspace_not_reporting` in the vectors shows
the three shapes together.

**A workspace can be created with setup turned off, and `setup.enabled` is how a client knows.**
It is false when somebody asked for no setup scripts at all: the repository is cloned and nothing
else is run, no services are started, and `setup.state` settles at `skipped` with a note saying so.
**`skipped` is then the ordinary outcome rather than something to fix**, so a client should offer to
run setup rather than report that it failed to, and `run_setup` is how a person asks for it. The
field is not named `run_setup` on purpose, because that is the method beside it and a field of that
name would read as a command. The machine's own configuration file does call it `run_setup`, which
is right where it is written: a file is read once and obeyed, so the key is a property there. It is absent only from a machine older than the key, and absent means
enabled, which is what those machines do.

**A client never has to guess what a new chat starts with.** `composer_defaults` on the workspace
snapshot is what a chat that does not exist yet would open on, as the machine answers it: the
repository's own settings file, then the built-in fallbacks, with the backend moved to one this
machine actually runs. Reading it is how the first chat in a workspace is opened on the right values
rather than on a client's idea of them. `composer` with **no** `chat_id` answers the same values
with the choices beside them (agents, models, slash commands, output styles), which is what a create
window needs to let somebody change them before anything exists; that answer carries no `chat_id`
either. Both come from one place on the machine, so they cannot disagree.

**`reporting` on the workspace record is the machine saying it cannot reach runbloom.app.** It is
absent almost always, and present with `unreachable_since` (when contact was lost) and `shed` (how
many unsent usage reports it has had to throw away) when there is something wrong to say. A client
should show it: the workspace is working, and what is being done in it is not being recorded
anywhere else. Everything else that fails between a machine and runbloom.app already fails in front
of somebody; this one is silent without it. `events.workspace_not_reporting` in the vectors is the
shape.

### Keeping a stream's token fresh

A stream outlives its token. At least a minute before the token expires, fetch a new one from
runbloom.app and send it:

```http
POST /_bloom/v1/streams/<Bloom-Stream-ID>/token
Authorization: Bearer <new session token>
```

204 means it took. A stream whose token runs out is closed with a `closing` event carrying
`token_expired`; open a new one with `Last-Event-ID`. A `closing` with `unauthenticated` means the
person no longer has access: do not reconnect.

## Terminals

```text
GET /_bloom/v1/terminal?name=<letters, digits, - and _, up to 64>
```

Upgrade to a WebSocket, then send the token as the first text frame within five seconds:

```json
{"kind": "auth", "token": "<session token with the terminal ability>"}
```

After that, binary frames are keystrokes one way and screen output the other. Text frames are
`{"kind": "resize", "columns": 120, "rows": 40}` and, before the token runs out,
`{"kind": "reauth", "token": "..."}`. A terminal's shell lives on after the socket closes;
reconnecting with the same name redraws it. The socket is closed with a policy violation for a
missing or bad token and with the reason `token_expired` when the token ran out.

## Preview

Open `https://<machine>/_bloom/preview/enter?token=<preview token>` in a browser, top level. The
machine sets `__Host-bloom-preview` (HttpOnly, Secure, SameSite=Lax, eight hours, one hour for a
share link) and redirects to `/`. Every other path is the project's own app, reached only with that
cookie; the app never sees the cookie.

## The client chapter

What #163 kept inside its Swift client, written down so every client gets it right.

### Opening a workspace

1. Ask runbloom.app for a session token. A 409 `machine_not_ready` means the machine is still being
   created: wait `retry_after` seconds and ask again. A 429 or 403 `limit_reached` is shown as
   runbloom.app wrote it; for `concurrent_machines` say it will carry on by itself.
2. If the answer says the machine is asleep, show that it is waking after 500 ms rather than a
   spinner with no words, and allow the first request at least ten seconds. A slow first answer is a
   waking machine, not a failure.
3. Send `workspace` and open the event stream with `Last-Event-ID` set to the `cursor` it returned.
   Opening the stream first is fine too; state events are sent whole, so either order converges.
4. For each chat you show, read its history with `transcript` pages (`after_seq` from -1, until
   `has_more` is false), then keep it current from `message` events.

### Merging history and events

A chat's rows are ordered by `seq`. A row may arrive twice, once in a page and once as an event; the
second copy is the same row and is dropped by `seq`. A row can arrive as an event before the page
that should have held it; keep it and let the page fill in around it. Remember the largest `cursor`
seen across all chats: that is the `Last-Event-ID` for the next connection, and the server sends
every row after it, so nothing is missed and nothing is fetched twice.

Streaming text is not a row. Show it after the last row while the chat is `busy`, replace it when a
`stream` event with `snapshot: true` arrives, append otherwise, and drop it when the assistant's row
arrives.

### Sending, and retrying safely

Give every mutation a command id (a UUID is fine) **before** sending it, and keep it with the
pending action. If the request fails in a way that leaves the outcome unknown (a timeout, a dropped
connection, a machine that paused mid-request), send the same operation again **with the same
command id**. The server answers a command it already ran with the reply it recorded, so nothing
runs twice. Never mint a new id to retry. An `outcome_unknown` reply means the server stopped in the
middle: refresh the chat and let the person decide.

A `send` answers `queued` with the prompt's id straight away; the turn starts when the queue gets to
it. The prompt stays visible in the chat's `queue` until it becomes a row. Prompts from several
people queue in the order the server received them, and none is ever written into a turn that is
already running.

A queued prompt's `state` is `queued`, `blocked` (a team limit: show `blocked.message`, and for
`concurrent_machines` say it will go when another Cloud workspace in the team goes to sleep) or
`uncertain` (it may have reached the agent before the server stopped; offer to remove it). A queue
with an `error` is paused; sending another message resumes it.

Drafts belong to the client and the person. Nothing is ever typed into anybody else's composer.

### Questions

A chat's `questions` are what its agent is waiting on. Anybody who can prompt can answer. The first
answer wins; a second gets `already_answered`, and the `questions` event that follows removes it.

### Composer

`set_composer` is last writer wins. The `composer` event says who changed it; show that when it was
somebody else. A chat that has messages keeps its agent: to change agents, open a new chat.

### Review

Ask `review_snapshot` with the revision you have and `wait: true` to be answered when it changes, or
after fifteen seconds with `files` absent when it has not. Keep patches by path and
`content_revision`, and send it as `known_revision` to `review_patch`: an absent `patch` means yours
is current. A `review` event is a hint to ask again sooner.

### Files

`file` answers a `revision`. Send it back with `write_file`; a `conflict` means somebody changed the
file since you read it, so read it again, merge, and write with the new revision.

### Presence

`presence` lists the people with the workspace open and when each last did something. Opening a
stream makes you present; it does not keep the machine awake. Typing a prompt, answering, a
keystroke in a terminal and saving a file do.

### Sleeping and waking

A machine sleeps when nobody has done anything for fifteen minutes, or two minutes after the last
stream closed, as long as nothing is running. Before it does, every stream gets `sleeping` and
closes. Do not reconnect straight away: show the workspace from runbloom.app's summary, and
reconnect on the next thing the person does, with a fresh session token and `Last-Event-ID`. That
request is what wakes the machine.

### Archiving

1. Send `archive_preview`. Show what would be lost: uncommitted changes, untracked files, unpushed
   and detached commits, a running agent. Always say the conversation is deleted with the Cloud
   workspace (`deletes_conversation`).
2. When the person confirms, send `archive` with the `confirmation_id`. An `archive_preview` in
   reply means something changed since; show it again.
3. On `accepted`, ask runbloom.app to archive the workspace
   (`DELETE /api/v1/cloud-workspaces/{id}`), which deletes the machine.

## For runbloom.app: control calls

`POST /_bloom/v1/control/<call>` with a control token, sixty seconds long, single use. Any 2xx is
accepted; the machine answers 202 and carries the work on.

| Call | Body | Does |
| --- | --- | --- |
| `stop` | `{"limit": "..."}` | stops running turns, marks queued prompts blocked, reports and lets the machine sleep |
| `limits-cleared` | `{}` | tries blocked prompts again |
| `revoke` | `{"user_id": "..."}` or `{"user_ids": [...]}` | refuses their tokens and preview cookies issued before it, closes their streams, removes their queued prompts, stops their running turn and ends the shells they opened; a `share:<id>` subject withdraws a share link's preview |
| `update` | `{"version": "...", "sha256": "...", "tag": "v... or runner-v..."}` | starts the bootstrap script for that release, which restarts the server |
| `environment` | `{}` | fetches team and project environment again |
| `shared` | `{}` | stops every agent process and ends every terminal holding a personal key or personal environment; a turn running on one ends with a row saying why, and queued prompts start on the team key |
| `secret-rotated` | `{}` | reads `/etc/bloom/workspace.json` again and uses its new workspace secret |

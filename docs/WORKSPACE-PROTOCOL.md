# The bloom-workspace protocol, version 1

How a client talks to a Cloud workspace: the Mac app, the iOS app later, and a web interface in
runbloom.app after that. A client in any language can be written from this page, the
[JSON Schema](../Protocol/v1/workspace-v1.schema.json) and the
[vectors](../Protocol/v1/vectors.json). Why the protocol has the shape it has is in
[REMOTE-WORKSPACES.md](REMOTE-WORKSPACES.md); this page says what it is.

The Swift types in `Packages/BloomProtocol` are the source. `WireVectorTests` fails when they stop
encoding to the checked-in vectors, and `python3 Protocol/v1/schema.py --check` fails when the
schema stops describing them or stops listing a kind they decode. Both run in CI.

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
| `workspace` | | `workspace`: the workspace, its chats, who is present, and the newest transcript `cursor` |
| `transcript` | `chat_id`, `after_seq` (-1 for the start), `limit` (at most 500) | `transcript`: rows after `after_seq`, `has_more`, questions, `busy`, `streaming_text`, the queue |
| `composer` | `chat_id` | `composer`: its controls, the agents installed on the machine, models, slash commands, output styles |
| `setup_output` | | `setup_output`: setup's state and the whole log so far |
| `files` | | `files`: every path git tracks or would track |
| `file` | `path` | `file`: text and `revision` |
| `download` | `path` | `download`: bytes, up to 8 MB |
| `review_snapshot` | `scope` (`branch` or `uncommitted`), `known_revision`, `wait` | `review_snapshot`: `revision`, and `files` unless you already had that revision |
| `review_patch` | `path`, `scope`, `known_revision` | `review_patch`: `revision`, and `patch` unless you already had it |
| `run_scripts` | | `run_scripts` |
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
| `rename_workspace` | `name` | `accepted` |
| `run_setup` | | `accepted` once setup has run again |
| `run_script` (`terminal`) | `id` | `terminal`: the terminal it runs in |
| `close_terminal` (`terminal`) | `name` | `accepted` |
| `archive` (`share`) | `confirmation_id` | `accepted`, or a fresh `archive_preview` when the answer moved |

`push` and `create_pull_request` act as the person who sent them: the machine registers a short turn
under their token for the one command, so GitHub sees them rather than the machine.

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
| `review` | a revision number | asks `review_snapshot` again |
| `presence` | who has the workspace open | replaces its copy |
| `workspace` | name, branch, pull request | replaces its copy |
| `sleeping` | nothing | see "Sleeping and waking" |
| `closing` | a failure | the stream ends; act on the code |

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

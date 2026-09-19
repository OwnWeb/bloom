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
| `quick_prompts` | | `quick_prompts`: the project's `prompts` (`id`, `name`, `prompt`, `symbol`, `new_chat`, `source`) and the `issues` with them |
| `search_code` | `query` (1 to 256 characters), `limit` (at most 200) | `code_matches`: `matches` (`path`, `line`, `column` in UTF-16 units, `text` cut at 400) and `truncated`. Case-insensitive, over exactly what `files` lists, skipping files over 1 MB and anything binary or not UTF-8. Every file is opened without following links, so a symlink out of the worktree is never read. Stops at the limit or after ten seconds, with `truncated` true |
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
| `write_file` | `path`, `text`, `revision` | `file` with the new revision, or `conflict` when the file changed since that revision. **An empty `revision` creates the file, and its folders, only if there is none**, answering `conflict` if one exists: that is how a client adds a `.bloom/settings.toml` a project does not have yet |
| `upload_file` | `name`, `data` | `text`: the path it was saved at, under `.bloom/attachments/` |
| `commit` | `message` | `accepted` |
| `push` | | `accepted` |
| `create_pull_request` | `title`, `body`, `draft` | `text`: the pull request's URL |
| `save_notes` | `text` | `accepted` |
| `revert_file` | `path`, `scope` | `accepted`: the file goes back, in the sense that scope has |
| `discard_hunk` | `path`, `scope`, `patch` | `accepted`, or a conflict when that hunk is no longer what the file holds |
| `rename_workspace` | `name` | `accepted` |
| `run_setup` | | `accepted` as soon as setup has started again, not when it ends: follow it through the `setup` event and `setup_output`, as for any setup. Refused on the spot with `busy` when setup is already running, an agent is working or a prompt is waiting. Sent for a workspace with `setup.enabled` false too: the person is asking for it by hand, which is the whole point of the key |
| `stop_setup` | | `accepted`, and setup ends as `failed` with a note naming who stopped it: the step running is ended and nothing after it starts, services included. What finished stays installed, and `run_setup` does the rest. Stops the machine's own setup or one run by hand, whichever is running; `conflict` when neither is |
| `continue_after_merge` | `chat_id`, optional | `text`: the new branch. After the pull request merged: a new branch cut from the base in this worktree, the same session kept, and the agent told in `chat_id` or the most recent chat, as the person who asked. Refused with `conflict` and the Mac's own sentence when the pull request has not merged, an agent is working, a rebase is half done, or the worktree is on another branch or detached. Needs `prompt` as well as `files` |
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
| `chat` | a chat | replaces its copy; one carrying `closed_at` is the last about that chat, which was closed, so drop it |
| `mac_message` | a message for a local workspace on this Mac | **Bloom on a Mac only**: check `user_id` is the signed-in person, find the local workspace named `workspace`, and deliver `text` into it as a message from elsewhere, headed with `via`, never as typed words. Sent only down streams opened with `Bloom-Client: mac` by the running turn's person; deliver each `id` once |
| `queue` | a chat's queued prompts and why it is paused | replaces its copy |
| `questions` | a chat's waiting questions | replaces its copy |
| `composer` | a chat's controls and `changed_by` | replaces its copy, and may say who changed it |
| `setup` | setup's state and step | replaces its copy |
| `setup_output` | new output | appends it to the log |
| `pane_requested` | a `url` the agent named, or none for this workspace's own address, and the `chat_id` it is speaking for | **open a browser pane, if you want to**; see below |
| `presence` | who has the workspace open | replaces its copy |
| `workspace` | name, branch, pull request, `reporting` | replaces its copy |
| `sleeping` | nothing | see "Sleeping and waking" |
| `closing` | a failure | the stream ends; act on the code |

**Refuse at the edge, be liberal at the leaf.** A word the machine does not know is refused there,
because an agent told it got what it asked for is the failure that matters; **a client draws an
unknown one as the default rather than discarding the event**, because a client that goes silent
over a word it has not learned goes blind the day a value is added. The two ends are deliberately
not symmetric, and both halves of that were argued for by the people who own them.

**`pane_requested` carries `placement`, `split` or `tab`, and absent means `tab`.** An agent asked
to put a browser "next to this chat" had no way to say so and got a tab, which is a different thing:
locally the two are different verbs, `pane_split` and `pane_open`. **A split belongs beside the pane
showing the chat that asked**, and a client that cannot split, or whose reader is not looking at
that chat, opens a tab instead. **The reader's selection is never moved for either**, which is a
bigger liberty than opening something.

**`pane_requested` is an agent on the machine asking, not telling.** It cannot open a pane: a pane
belongs to the window of whoever is looking, and the machine is not there. So a client shows one if
it wants to, and may ignore it. **Several clients may receive the same request**, and there is no
"the" window, so each decides for itself. No `url` means this workspace's own public address, which
a client connected to it already knows. The tool that sends it tells the agent how many clients were
told, and tells it plainly when there were none, so **an agent is never in a position to report
opening something that did not open**.

**Knowing when the diff changed is the waiting `review_snapshot` call.** Ask with the `revision` you
hold and `wait` true: the machine answers at once with a new `revision` and `files` when the diff has
moved, and after about fifteen seconds with the same `revision` and no `files` when it has not, which
is the signal to ask again.

**There used to be a `review` event here and it was removed on 18 September 2026, because no machine
had ever sent one.** Nothing constructed it: the case and its decoder were the only two places it
appeared in the whole of Bloom, and its `revision` was an integer where the snapshot's is a digest
string, so the two could not have been compared even if it had arrived. A client had already written
a refresh path on it, which therefore never ran. **An event nothing emits is worse than no event**:
it reads as a mechanism, and the client that trusts it has no symptom to debug.

## Addressing a message

**`send` takes an optional `audience`, and absent means the agent**, so a client that has never
heard of this keeps working. It is `{"kind": "agent"}` or `{"kind": "person", "user_id": "…"}`,
**always by id and never by a typed name**: addressing by display name sends to the wrong person the
day two people share one. A `kind` the machine does not know is refused rather than read as the
agent.

**A message addressed to a person does not become a turn.** It is not queued, it sends no queue
event, it does not change the chat's state, it does not interrupt whatever the agent is doing, and
`send` answers `accepted` rather than `queued`: there is no prompt to wait for.

**And the agent is never given it.** Not filtered at the client, not marked and passed on, and not
included by any later replay or compaction: `chat_read`, the only way an agent can read a
transcript, leaves these rows out. **The agent is told nothing about the gap**, because a "messages
not shown" marker invites it to ask what it missed. **This is a property of the protocol rather than
of one implementation**, so a client may rely on it and a machine may not weaken it.

**The mention travels resolved, in `audience.mention`, and is never re-parsed.** It is the text that
was typed, `@sebdd` or `@agent`, and it is **always a prefix**, so its extent is its own length and
there are no offsets to disagree about; two clients that each hunt for the `@` will differ the first
time somebody types `@seb.dd`, and an offset computed in UTF-16 code units by one client and
graphemes by another puts a highlight in two places. **The machine strips the mention from what the
agent reads** and nowhere else: the agent is asked "Fix the server", not "@agent Fix the server",
while the stored row keeps what was typed because the bubble draws it. A client must not strip it
early.

### Which client is watching

Bloom on a Mac opens the event stream with `Bloom-Client: mac`. The machine believes it only for
choosing which of one person's own streams a `mac_message` goes down, so a browser holding the same
person's stream is never handed a message meant for their Mac. Other clients send nothing.

### Sent by an agent

A client that sends on a person's behalf because an agent asked it to, the Mac's `workspace_say` to
a Bloom Cloud workspace being the first, adds `via` to `send`: `{"kind": "agent", "workspace",
"chat"}`, the sending workspace's name and chat's title. **The token is still the person's, so the
message is theirs**: their author, their turn, their bill. `via` is what stops it reading as words
they typed. The machine keeps it on the row, and every client draws it under the author.

- **A label, never a permission.** It grants nothing, changes nothing about the author, and is
  never handed to an agent. The machine believes it only for what it says on screen.
- **Names, not ids**, because it is only ever read, and a Mac's workspace id means nothing here.
- `kind` is `agent` and nothing else yet; the machine refuses any other with `invalid_value`, before
  anything is written. Each label is trimmed and cut at 200 characters.
- From a person's own client, with no agent involved, there is no `via`.

## The terminal socket

Verified against the code rather than described from memory, because two clients have now had to
work it out for themselves.

**`GET {machine_url}/_bloom/v1/terminal?name={name}`, upgraded.** The scheme is the machine URL's
with `http` swapped for `ws`. **No token in the URL and none in a header**: a browser's `WebSocket`
can send neither, so it goes in the first frame and every client takes the same path, which is the
one that gets tested.

**The first frame must be `auth` and must arrive within five seconds**, or the machine closes with
`1008`. Anything before it is refused the same way. **A `1008` means refused, and reconnecting will
not fix it**: the reason says which refusal it was, and `token_expired` is the one a client acts on
by getting a fresh token rather than retrying. The abilities needed are `view` and `terminal`.
Frames are capped at 1 MB in both directions.

**Binary up is keystrokes. Binary down is raw PTY bytes with no envelope**, which is what a terminal
emulator wants and nothing else. **Text up is the three control frames** (`auth`, `reauth`,
`resize`); **nothing comes down as text.** What a machine has to say beyond bytes it says by closing
with a reason.

**Connecting with a name attaches to that shell, or creates it.** There is no `open_terminal`
operation and that is not an omission: the name is the request. `run_script` is a different thing,
for the scripts `run_scripts` lists. **The shell outlives the socket**, so closing a tab and opening
another with the same name is the same session with its scrollback and its running command.

**`reauth` is the client's own clock.** A session token lives minutes and a terminal lives hours;
the machine never asks for a renewal and closes with `token_expired` when the deadline passes, so a
client watches its own expiry and sends `reauth` before it. **A renewal is verified as the same
person, still holding both abilities, and is ignored silently otherwise**: `reauth` cannot hand a
running shell to somebody else, and cannot carry one past the moment its owner's access narrowed.

**A server is held to sending every field; a client is held to reading what a machine actually
sends.** The two halves of this protocol are not held to the same standard on purpose. What a
machine sends is whatever was true when that machine was built, and every machine in the field was
built before the newest field existed. **So a client decodes an absent field as its default and
never as an error**, and a machine that has been running for a month keeps working when a client is
updated. The failure this prevents does not look like a missing field: a required key inside the
workspace snapshot means **that workspace will not open at all**. `members`, `fast_mode`,
`output_style` and `codex_context_window` are all read that way, and a default written on a stored
property does not do it: only an explicit decoder does.

**Who may be addressed is `members` on the workspace snapshot, and it is not `presence`.** Presence
is who is here; this is who has access, and **somebody who is away is exactly who a mention is most
useful for**. Each carries a `handle`, which is what a person types after `@`: a display name is not
typeable and an address is not either. **A handle belongs to a membership rather than to a person**,
so the same person may be `seb` in one team and `sebdd` in another, and a client must not cache one
across workspaces. There are no addresses in the list, because a share-link guest reads this
snapshot too and a directory of every member's email would be a way to collect them by typing `@`.
It is empty until the machine has been told, which is a real state and not an empty team.

**The machine refuses an audience it cannot vouch for**, and says which of the two it is: the person
is not a member of this team, or this machine has not been told who the team is yet. Both are
refusals rather than a stored guess.

**`author` is absent when nobody wrote it, and it is never cleared for whoever is reading.** It is
missing on the agent's own rows, on anything the machine wrote, and on every row in a Mac workspace,
where there is one person and no author to record. **It is present, with the same value, for
everybody**: the event stream encodes one `message` record and sends it to every subscriber, so a
per-reader field is not something this protocol can express, and anything that has to differ by
reader has to be a reply to a call rather than an event.

**So a client decides whether a message is its own by comparing `author.user_id` with the subject of
the token it authenticated with, never by the field being absent.** The subject, rather than "the
signed-in account", because that is the id the machine records and it is the one every caller has,
including before an account object has finished loading.

**A share-link guest does not come into it.** A share mints a **preview** token, whose only ability
is `preview`: it cannot open a chat, cannot send, and carries no author at all. **There are no
guest-written messages to decide the ownership of**, so a client that finds itself reasoning about
one has a different problem.

 "No author means mine" is true on a Mac, where nobody
has one, and wrong in a shared Cloud workspace, where it draws the reader's own words as somebody
else's, in somebody else's colour, with a caption naming them over the top of their own sentence.

**Every message has an author, and drawing it is one rule: the name if it is not empty, the email
if it is, and "somebody" if neither.** `AuthorRecord` carries `user_id`, `name` and an optional
`email`, and **`name` may be empty**, because not everybody has a display name. An empty name drawn
as-is is an empty label, which in a shared workspace is indistinguishable from no label, which reads
as the reader's own message: on 18 September 2026 Freek read a colleague's message as his. The email
is a field of its own rather than something put in `name` when a name is missing, because **mention
completion matches on these**, and a field that is sometimes a name and sometimes an address is how
a message meant for one person reaches another. `email` is absent for a share-link guest.

**A person with no display name is not refused.** The machine used to require a `name` claim on a
session token and turn away anybody runbloom.app had no name for, which is a worse answer than an
unlabelled message.

**The workspace record carries the project's services, and a client should draw them.** One entry
per `[[services]]` the repository declares, each with its `state` (`waiting`, `starting`, `running`,
`not_ready`, `crashed`, `stopped`), how many times it has restarted, a sentence for a person, and
**`http`, which marks the one the preview routes to**. That mark is a fact rather than an
instruction: **"can I open the preview yet" is that service and no other, and "why is it not up" is
usually a different one**, because what holds an app back is the database it waits for. Two clients
wanted opposite things from it and both were right, so the machine says which it is and neither has
to guess from a name.
**The state worth drawing loudest is `waiting`**: the machine starts a service only once everything
in its `depends_on` is ready, so one whose dependency never comes up is never launched, never fails
and never restarts, and before this record its only account was a sentence on the preview's own
error page, which a project running its own proxy on the previewed port makes unreachable. The list
is empty for a project that declares no services, and `workspace_not_reporting` in the vectors shows
the three shapes together.

**Every line the machine writes into the setup log itself begins `[bloom] `, and every other line is
the script's own output.** A client can draw the two differently on that alone: the step headings
(`[bloom] Cloning the repository.`), the notes (a settings problem, a run starting again, why
nothing ran) and the outcome sentences are Bloom speaking; everything else is what the project
printed.

**The step ids, which are the whole set**: `environment`, `git`, `clone`, `prepare`, `setup`,
`resume`, `services`. A run shows the ones it needs, in that order: a project with no scripts shows
`environment`, `git`, `clone` and, if it declares any, `services`, and a later start shows
`environment`, `git`, `resume`, `services`. **Three of them normally print nothing worth reading**:
`environment` and `git` are silent unless something goes wrong, and `services` says one line. So
**an empty log under a named step is the ordinary case rather than a sign that nothing is
happening**, and **the step is always set before the work starts**, which makes it a promise the
machine has already kept rather than one it is about to. The step is the state; the log is the
detail.

**A script cannot speak in Bloom's voice**: a line of script output that begins with the marker is
indented by one space before it is stored, so it keeps every character and stops being a line that
starts with `[bloom] `.

**A workspace can be created with setup turned off, and `setup.enabled` is how a client knows.**
It is false when somebody asked for no setup scripts at all: the repository is cloned and nothing
else is run, no services are started, and `setup.state` settles at `skipped` with a note saying so.
**`skipped` is then the ordinary outcome rather than something to fix**, so a client should offer to
run setup rather than report that it failed to, and `run_setup` is how a person asks for it. The
field is not named `run_setup` on purpose, because that is the method beside it and a field of that
name would read as a command. The machine's own configuration file does call it `run_setup`, which
is right where it is written: a file is read once and obeyed, so the key is a property there. It is absent only from a machine older than the key, and absent means
enabled, which is what those machines do.

**A failure the machine can name carries `setup.failure_code`.** `setup_needs_fresh_machine` is the
only code today: setup asked for root, and only the first setup of a brand new machine on the base
branch's own code gets it (see "The sandbox user" in docs/REMOTE-WORKSPACES.md). `note` and the log
say the same thing in words and name the command that was refused, but the code is what a client
should offer an action from, because the words will be reworded. It is absent on an ordinary failure
and on any machine older than the field, and both mean "read the note". The codes live in one list,
`SetupFailureCode`.

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
machine sets `__Host-bloom-preview` (HttpOnly, Secure, SameSite=Lax, one hour, for a person and a
share link alike) and redirects to `/`, or to `path` when one is given: `&path=/dashboard`, for a
`pane_requested` that named a page. **Only a path on this origin is taken**: it has to start with one
`/`, carry no backslash or control character, stay out of `/_bloom`, and fit in 2,048 bytes; anything
else lands on `/`, so the entrance can never be used as an open redirect. Every other path is the
project's own app, reached only with that cookie; the app never sees the cookie.

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

**A model's own efforts and fast tier are on its record.** `models` lists Codex's and Claude
Code's, each with the `efforts` it takes; Codex's also carry a `default_effort`. `fast_tier` names
the service tier that makes a Codex model fast, from the same model list and without starting a
turn. **Absent means no fast mode**, which is also what a machine older than the field sends, and
it is always absent on a Claude Code model, whose fast mode is a switch on the chat. A project's
Codex configuration can still turn fast mode off, and that is not on the wire yet.

**Claude Code's list is the `claude` CLI's own**, read from its `initialize` answer, and it depends
on who asks. A machine asks without an account, because it holds no key outside a turn, and the
CLI then leaves out models an account unlocks: **Fable is absent from a machine's list, and that is
not a bug.** A chat can still be set to a model the list does not carry; the list is what the machine
can vouch for, not everything that will run. `[1m]` variants such as `opus[1m]` are their own model
ids, and `is_default` marks the one the CLI recommends.

**Quick prompts come from two places, and the machine answers for one.** The person's own are in
their client's database and are that client's to show. The project's are `[[quick_prompts]]` in the
repository's settings files, which only the machine can read, and `quick_prompts` answers with
them, read by the Mac's loader so the two menus cannot disagree about a file.

- **Ask when the menu opens, not once.** The file is read again on every call and nothing is
  pushed, so an edit in the workspace, a pull, or an agent rewriting the file is in the next menu.
  Quick prompts are the same for every reader, so this could have been the snapshot; it is a call
  because a snapshot is fetched once and the file is not.
- **A project prompt never sends.** Put `prompt` in the composer for the person to read. There is
  no `send_immediately` on the wire: the machine refuses it on the way in and says so in `issues`,
  because these are words whoever last edited a committed file wrote, and an agent with the run of
  the worktree acts on them the moment they are sent.
- **`new_chat`** opens a new chat for the words, titled with `name`. Where a new chat cannot be
  opened, compose in the one on screen.
- **`symbol`** is always one Bloom draws: an SF Symbol name from Bloom's picker, or one emoji. A web
  client that cannot draw the first needs its own mapping or a fallback glyph.
- **`id`** is the name trimmed and lowercased, stable across reads and unique in one answer, so a
  highlighted row stays highlighted when the menu is read again.
- **`issues`** are sentences about the project's prompts only, each with its `source` relative to
  the worktree and a `line` when the parser had one: a prompt left out, one that will not send on
  its own, a file that would not parse and took its prompts with it.
- **A machine older than this call answers 400 `invalid_request`.** Treat that as no project
  prompts.

### Media

An agent on a machine shows a picture with `media_show`, and the chat gets a `message` of kind
`media`. Its payload is `path`, `name`, `caption`, `kind` (`image` or `video`), `mime` and `bytes`.
**It is a reference, never the bytes**: fetch `path` with `download`, as any file, and draw it inline
where the row sits, with `name` under it and `caption` beside it when there is one.

- `path` is a copy in the worktree's git-ignored `.bloom/scratch/media/`, named by its digest, so it
  never changes under a row and never reaches the diff.
- Images are PNG, JPEG, GIF, WebP and AVIF; videos MP4, MOV and WebM; each at most 8 MB, which is
  what `download` carries. The machine reads the type from the file's bytes, never its name. **SVG
  is refused**, because it can carry script. Draw an image as an image (an `img`, an `NSImage`),
  never as a document.
- The agent's own `media_show` call is in the transcript too, just before the `media` row. Draw it
  as an ordinary tool call, or fold it away: its `path` is the machine's, and there is nothing on
  a client's disk at that path.

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
| `update` | `{"version": "...", "sha256": "...", "tag": "v... or runner-v...", "download_url": "https://objects.githubusercontent.com/..."}` | starts the bootstrap script for that release, which restarts the server. `download_url` is optional: a short-lived signed URL on `objects.githubusercontent.com` or `release-assets.githubusercontent.com`, fetched with no redirect followed and never logged, since the repository is private; the sha256 still decides |
| `environment` | `{}` | fetches team and project environment again |
| `shared` | `{}` | stops every agent process and ends every terminal holding a personal key or personal environment; a turn running on one ends with a row saying why, and queued prompts start on the team key |
| `secret-rotated` | `{}` | reads `/etc/bloom/workspace.json` again and uses its new workspace secret |

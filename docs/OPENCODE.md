# The OpenCode ACP protocol

Ground truth, captured from `opencode` 2.3.2 on this machine on 2026-11-19. Every fact below was
measured with the XDG data, config, state and cache directories pointed at a temporary folder, a
scratch working directory, and turns run on a local Ollama model only. What was read from the
binary rather than observed on the wire says so.

OpenCode speaks ACP, the same JSON-RPC protocol as Grok (`docs/GROK.md`), so the two backends share
the wire layer in `Sources/BloomCore/Agent/ACP/` and nothing else. The dialects differ in how the
process is launched, how a model and an effort are set, and how permissions are decided.

## How Bloom invokes it

```
opencode acp
```

No flags. `acp` has none worth using: `--auto` and `--session` exist only on the root command.

The child environment carries two additions:

- `OPENCODE_DISABLE_AUTOUPDATE=1`, so an update cannot start underneath a chat.
- `OPENCODE_CONFIG_CONTENT`, a JSON config holding only a `permission` block, when the chat's
  permission mode needs one. See Permissions.

Working directory is the worktree. Input is JSON-RPC on stdin, one message per line, and output is
JSON-RPC on stdout. Nothing else was ever seen on stdout across every measured run. stderr is
silent unless `--print-logs` is passed. Behaviour without `OPENCODE_DISABLE_AUTOUPDATE` was not
measured, because measuring it could have updated the owner's install.

`clientCapabilities` is sent empty, for the reason Grok's is: advertising `fs` or `terminal` makes
the agent ask Bloom to read files and run commands.

### One private server per chat

`opencode acp` always starts its own server: a child `opencode serve --stdio --port 0`, protected
by a random password. This is read from the binary (the `acp` command calls the standalone
endpoint and never the code path that resolves the background service) and observed in isolation.
It follows that a Bloom chat never attaches to the owner's `opencode serve --service`, and that
stopping a chat cannot stop a turn of theirs.

The child server exits with its parent on stdin close (exit code 0), on SIGTERM and on SIGKILL,
each observed within half a second.

Not measured: a private server and the background service both open on the real data directory.
Both use the same SQLite database there, so a Bloom chat is expected to show up in the owner's
session list. Measuring it means touching the owner's real OpenCode data, which the measurements
were not allowed to do.

OpenCode reads `~/.agents/skills` and, unless `OPENCODE_DISABLE_CLAUDE_CODE` is set, Claude Code's
own configuration. Neither is isolated by XDG. Bloom sets neither variable: a chat should see what
the user's own `opencode` sees.

## Handshake

1. Client `initialize` with `protocolVersion: 1` and `clientInfo`.
2. Server replies with `agentInfo {name: "OpenCode", version}`, `agentCapabilities`
   (`loadSession`, `sessionCapabilities {close, delete, fork, list, resume, additionalDirectories}`,
   `promptCapabilities {image, embeddedContext}`, `mcpCapabilities {http: true, sse: false}`),
   `authMethods` (one, `opencode-login`) and `_meta.steering.supported: true`. **There is no
   model list here**, unlike Grok's `_meta.modelState`.
3. Client `session/new {cwd, mcpServers}`, or `session/resume {sessionId, cwd, mcpServers}`.
4. Server replies with `sessionId` (`ses_…`, on `session/new` only) and `configOptions`.

No `initialized` notification is needed.

`session/resume` after a process restart keeps the conversation: a turn after it recalled a word
from the turn before. Its reply carries `configOptions` and no `sessionId`. It replays nothing,
which is why Bloom uses it and never `session/load`, whose replay would double the stored rows.
The `cwd` must be the session's own: another one is refused with `-32602`, "session … does not
belong to cwd", and an unknown id with `-32602`, "session not found".

Just after either call comes a `session/update` of kind `available_commands_update`.

With no provider at all, `session/new` fails with `-32603`, "Internal error: No models are
available", `data.errorName: "CatalogNotReady"`. It is not `auth_required`. A stock install is
never in that state, because OpenCode ships hosted free models that need no account.

## Config options

`configOptions` is a list of selects, each with `id`, `category`, `currentValue` and `options`:

| id | category | values |
| --- | --- | --- |
| `model` | `model` | `provider/model`, for example `ollama/qwen3.5:4b` |
| `effort` | `thought_level` | depends on the current model, for example `none`, `high`, `default` |
| `mode` | `mode` | `build`, `plan` |

**The `effort` option is absent when the current model has no effort levels.** Of the fourteen
models listed here, six had none.

`session/set_config_option {sessionId, configId, value}` takes `value` as a **bare string** and
returns the whole `configOptions` again. Grok's `value: {value: …}` is refused with `-32602`. An
unknown model is `-32602` "model not found", an unknown effort `-32602` "effort not found".

The default model of a new session is whatever OpenCode picks, which on a stock install is a
hosted free model. Bloom always sets the composer's model before a turn.

### Discovering models

`opencode models` goes through the background service and tries to start one, so it is not used.
Bloom opens a short ACP connection instead: `initialize`, `session/new` in a scratch directory,
read the `model` option, then `session/set_config_option` once per model to read that model's
`effort` option, then `session/delete` and close stdin. Measured: handshake and session in 0.5
seconds, fourteen models walked in 0.02 seconds, and `session/list` empty after the delete, so
discovery leaves nothing in the user's session history. No prompt is sent, so nothing is spent.

One run out of roughly fifteen listed the configured providers without the locally detected Ollama one:
provider detection is asynchronous and a session created early can miss it. A
`config_option_update` notification follows when the list changes.

## A turn

`session/prompt {sessionId, prompt: [{type: "text", text}]}` is held open until the turn ends.
Updates arrive as `session/update` notifications:

- `agent_message_chunk` / `agent_thought_chunk`, `content {type: "text", text}`.
- `tool_call`, then `tool_call_update`. The first frame has `name`, `title`, `kind` and an empty
  `rawInput`; the input arrives on the `in_progress` update, and the result on the `completed` or
  `failed` one as `content` blocks plus `rawOutput`. The tool is named by `name`, not Grok's
  `toolName`. Seen: `write` (`kind: edit`), `shell` (`execute`), `read` (`read`), `execute`
  (`other`).
- `usage_update {used, size, cost}`, once at the end of the turn. This is the context gauge.
- `config_option_update`, `available_commands_update`, `session_info_update` (ignored).

The reply is `{stopReason, usage {inputTokens, outputTokens, totalTokens, cachedReadTokens}}`.

A second `session/prompt` during a turn is refused: `-32603`, "Session already has an active ACP
prompt".

A turn that cannot reach its provider retries on its own, announcing each attempt in
`session_info_update` `_meta["opencode/retry"]`, and after about ninety seconds fails the prompt
request itself with `-32603` and `data.errorName: "provider.transport"`.

`session/cancel` is a notification. The prompt replies `stopReason: "cancelled"`, an unfinished
tool call goes to `failed`, and a pending permission request is withdrawn with a
`$/cancel_request {requestId}` notification.

### Steering

`_session/steering {sessionId, prompt}` during a turn replies `{outcome: "injected"}` and the
model takes the message into the same turn. With no turn running it replies
`{outcome: "promptRequired", reason: "noRunningTurn"}`. Bloom does not send it yet, so
`AgentKind.acceptsMidTurnMessage` stays false for OpenCode and a message typed during a turn
waits for the turn to end.

## Permissions

OpenCode decides permissions from its config, as an ordered list of rules where the last match
wins. The defaults on 2.3.2 allow everything except reading `.env` files, which asks. So a chat
launched with no configuration never asks before editing a file or running a command.

There is no launch flag and no session parameter for this. `OPENCODE_CONFIG_CONTENT` is the lever:
it is merged after the user's global config and the project's `opencode.json`, so its rules are
the last ones and win. Measured with `opencode debug agents`: a user config with a provider, an MCP
server and its own permission rules kept all three, and gained Bloom's rules at the end.

| Bloom mode | Injected `permission` |
| --- | --- |
| Ask (`default`) | `{"edit": "ask", "shell": "ask"}` |
| Accept edits | `{"shell": "ask"}` |
| Bypass | nothing: OpenCode's own configuration decides |

Bloom names two actions and never `"*"`. A wildcard rule would also be the last match for
everything the user had denied, and for the `.env` rule above. The cost of the injection that
remains: a user whose own config denies `edit` or `shell` is asked instead of refused.

The mode is fixed at launch, so changing it restarts the chat's process, as Grok's
`--always-approve` does.

`session/request_permission` is a server-to-client request whose ids count from zero. Its
`toolCall` carries `toolCallId`, `name`, `title`, `kind`, `locations`, `rawInput` and, for an
edit, a `diff` content block. The options are always the same three:

| optionId | kind |
| --- | --- |
| `once` | `allow_once` |
| `always` | `allow_always` |
| `reject` | `reject_once` |

**Rejecting ends the turn.** The tool call fails with "The user declined this tool call" and the
prompt replies `stopReason: "cancelled"`. There is no deny that lets the model carry on.

## MCP

`mcpServers` on `session/new` and `session/resume` takes a stdio server as
`{name, command, args, env}` with `env` an array of `{name, value}` objects, the shape Grok
takes. It is additive over the user's own config. Measured with a stub server: it was started
with its environment, listed its tools and was called.

OpenCode does not hand MCP tools to the model as tools of their own. They are reached through its
`execute` tool, which runs a JavaScript body with the servers as namespaces:
`return await tools["bloom-workspace-bridge"].whoami({})`. A bridge call therefore shows in the
transcript as an `execute` tool call. No permission question was asked for it under the Ask mode's
rules. A small local model needed the exact expression spelt out before it managed the call.

The owner's own client is registered with `opencode mcp add --global <name> --env KEY=value --
<command…>`.

## Attachments

Bloom names an attachment by its path inside the prompt text, as for every backend. Measured with
an image at `.bloom/attachments/x/img.png`: the `read` tool read it without a permission question
and a vision model named its colour. The tool result carries the image as a base64 content block,
which Bloom does not store.

## Sign in and credentials

Credentials live in OpenCode's SQLite database under the data directory, not in a file Bloom
could read without opening that database. Bloom therefore shows no account for OpenCode, and
treats a non-empty model list as "ready". Signing in is `opencode auth login`, run by the user.

Global configuration is the directory `~/.config/opencode/` (`opencode.json` or `opencode.jsonc`).

## Left out, and why

- **Quotas and usage limits.** ACP carries none. The only source seen is the experimental HTTP
  route for OpenCode's own subscription, which says nothing of a provider's quota.
- **Several accounts.** Isolating OpenCode's sign in means moving its data directory, and the
  session history lives there too.
- **The automatic router.** It needs a small reliable model per backend, and OpenCode's depends on
  which providers the user connected.
- **Image content blocks, `session/list`, `session/fork`, `session/load`.**

Measured but not wired yet: steering (above), and plan mode, which is the `mode` config option.
Not measured: subagent updates (`_meta["opencode/child-session-updates"]`), `elicitation/create`,
and whether `opencode -s <id>` opens an ACP session in the terminal interface.

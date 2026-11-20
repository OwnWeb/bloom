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

Two `acp` processes on one data directory share its database: each lists the other's session.
So a Bloom chat is expected to show up in the user's own session list. Each private server
starts its own `opencode-pty` daemon under a name of its own, which exits with it; closing one
process left the other's shell calls working. Measured on an isolated data directory only. The
real one, next to a running `opencode serve --service`, was not touched.

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

**The `effort` option is absent when the current model has no effort levels.** Of the thirteen
models listed here, six had none.

`session/set_config_option {sessionId, configId, value}` takes `value` as a **bare string** and
returns the whole `configOptions` again. Grok's `value: {value: …}` is refused with `-32602`. An
unknown model is `-32602` "model not found", an unknown effort `-32602` "effort not found".

The default model of a new session is whatever OpenCode picks, which on a stock install is a
hosted free model. Bloom always sets the composer's model before a turn, and its effort when the
model offers it, so a model or effort changed in the composer is taken by the next turn on the
same process and the same `ses_…`. The work mode goes the same way (see Plan mode). Only a
permission mode change restarts the process.

### Discovering models

`opencode models` goes through the background service and tries to start one, so it is not used.
Bloom opens a short ACP connection instead: `initialize`, `session/new` in a scratch directory,
read the `model` option, then `session/set_config_option` once per model to read that model's
`effort` option, then `session/delete` and close stdin. Measured: handshake and session in 0.5
seconds, thirteen models walked in 0.02 seconds, and `session/list` empty after the delete, so
discovery leaves nothing in the user's session history. No prompt is sent, so nothing is spent.

Provider detection runs after `session/new` returns. A session opened right after `initialize`
missed the local Ollama provider in four runs out of twenty. A `session/update` of kind
`config_option_update` followed within four seconds in all twenty, and the last one always had
it; one run announced twice, the first time without Ollama. So discovery waits five seconds and
reads the model list from the last announcement, and a turn whose model is refused waits once for
an announcement that offers it.

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
prompt". So is one sent straight after `session/cancel`, before the cancelled prompt has
replied. Bloom waits for that reply before the next prompt.

The session title is written by OpenCode's hidden `title` agent. With no model configured for it,
the binary picks the small model of the session's own provider, else the session's model, so a
chat on a local model does not send its first message to another provider.

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

Ask and Accept edits also carry an `agent` block that puts back the built-in agents' denials these
rules would reopen. See Plan mode.

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

**`allow_always` outlives the chat.** Measured on 2026-11-19: it covers the exact command (`ls -a`
asked again after `echo one` was always allowed), but the same command then ran without a
question in a new session and after the process was restarted on the same data directory. Bloom
therefore answers every allow with `allow_once` and keeps the grant itself: a session grant in
`OpenCodeRunner`, forgotten with the process, a project grant in `SessionGrants`, which can be
revoked from Bloom. Either answers the next matching question without a card.

## Plan mode

Measured on 2026-11-20 on 2.3.2, with `HOME` isolated as well as XDG, because the plan agent's
own directory is `$HOME/.opencode/plan`, which XDG does not move. It is under the home directory
whether or not the working directory is a git repository, so a plan file never lands in the
worktree.

The `mode` config option (`build`, `plan`) selects OpenCode's `plan` agent. Setting it returns
the whole `configOptions`, like the model and the effort. **It is stored with the session**:
`session/resume` in a new process reports `currentValue: "plan"`. A chat that left plan mode has to
say `build` again, or its next turn still plans.

What the plan agent may do comes from its default rules, read with `opencode debug agents`:

    *:*=allow ... edit:*=deny edit:$HOME/.opencode/plan/*=allow

So it may not edit outside its plan directory, and **it may run any command**. Nothing in the plan
agent restricts the shell. With no rule injected (Bloom's bypass mode), a plan turn asked to
create a file wrote it with `printf … > a.txt` after its `write` call was refused.

A refused edit is a failed tool call with "Cannot use write to modify files outside the Plan
directory: <dir>", no permission request, and the turn carries on to `stopReason: "end_turn"`.
Unlike a rejected card, it does not end the turn.

**The injected permission block outranks the plan agent's deny.** Rules are appended in order, the
agent's defaults first, then the user's config, then `OPENCODE_CONFIG_CONTENT`, and the last match
wins. Ask mode's `edit: ask` therefore comes after `edit:*=deny`, and also after the plan
directory's allow:

| Bloom mode | Plan agent, edit in the worktree | Shell |
| --- | --- | --- |
| Ask, `{"edit":"ask","shell":"ask"}` | a card; `allow_once` wrote the file | a card |
| Accept edits, `{"shell":"ask"}` | refused | a card |
| Bypass, nothing injected | refused | runs, no card |

The same append reopens other agents' denials: `explore`, `summary` and `title` start from
`*:*=deny`, and the Ask block gives each `edit:*=ask` and `shell:*=ask`. That fails towards a
question rather than towards a silent edit, so it went unnoticed until plan mode was measured.

An agent's own rules can be appended after the global block, under `agent.<id>.permission`, and
`{env:HOME}` is expanded in a rule. With

    {"permission": {"edit": "ask", "shell": "ask"},
     "agent": {"plan": {"permission": {"edit": {"*": "deny", "{env:HOME}/.opencode/plan/*": "allow"}}}}}

the plan agent ends `... edit:*=ask shell:*=ask edit:*=deny edit:$HOME/.opencode/plan/*=allow`, and
a plan turn's `write` into the worktree was refused without a card while its commands still asked.
A `write` into `$HOME/.opencode/plan/` went through with no card. Object keys keep their order, so
the `*` rule stays before the path; the order of `agent` and `permission` does not matter.

**What Bloom injects, therefore.** `OpenCodePermission.restoredDenials` puts back, after the global
block, each built-in denial an injected action would reopen: the plan agent's edit rules,
`explore`'s edit, and `summary`'s and `title`'s edit and shell. Only denials: `explore` allows the
shell by default, and Bloom's `ask` on it is a tightening that stays. The cost: an agent named here
that a later OpenCode drops comes back as an extra agent with these rules, listed as a value of the
`mode` option (measured with a made-up name), which Bloom never selects; and a user who loosened one
of these built-in agents in their own config is denied again inside Bloom.

**Plan with Bypass adds nothing.** In Bloom the work mode and the permission mode are two axes, as
they are for Codex, whose plan turns on Full access run with no sandbox and no approval. So a
Bypass plan chat runs the plan agent under OpenCode's rules: edits refused, commands free.

**The mode is sent whenever the session holds another**, after the model and before the effort, so
a resumed chat or one that left plan mode is put back to `build`. A mode the session does not offer
fails the send, unlike an effort, because a plan turn run as `build` would edit the worktree. A
session that offers no `build` is left on its mode: only a plan run as a build is worth refusing.
A session whose mode is one of the user's own primary agents is put back to `build` by the next send.

Not measured: whether the plan agent can hand an edit to the `general` subagent, which under
Accept edits and Bypass is allowed to edit.

**A plan turn ends like any other turn.** With the hosted `opencode/deepseek-v4.1-flash-free`, a
plan turn read the code, ran two commands (each a card under Ask), and wrote the plan as its reply,
ending on `end_turn`. It wrote no plan file, no `session/update` announced a mode change, and no tool
to leave plan mode was called, so the plan is the transcript's last message and nothing else.
Bloom therefore records the last text block of a plan turn that ends on `end_turn` as the chat's
plan, the artefact Codex's plan item and Claude Code's `ExitPlanMode` give it, with Refine and
Implement under it. (The
local `qwen3.5:4b` never managed to write a plan file either: it aimed `write` at the directory.)

On the way it called the `question` tool. With `clientCapabilities: {}` that call fails at once with
"The question couldn't be shown to the user in this client. Continue without an answer: make
reasonable assumptions and state them, or ask the user in your reply if you can't proceed.", and the
model carried on with its recommended option and said so in the reply. Answering it is
`elicitation/create`, a separate piece of work.

**A model change keeps the mode.** Switching the model of a plan session left `mode` at `plan`.

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

Measured on 2026-11-19, under the Ask mode's rules: `execute` is a sandbox. `node:fs`,
`node:child_process`, `Bun` and `global` are all refused inside it, and no file was written, so
what it reaches is the MCP servers. An MCP call through it asks only under a rule naming that
server's tool, `<server>_<tool>` (`fake-bridge_whoami: ask` asked). `execute: ask` and `*_*: ask`
asked nothing, and `"*": ask` asked but would also outrank every rule the user denied. So Bloom
adds no MCP rule, and the Ask mode says that MCP tools follow the user's own rules and run
without asking by default.

The owner's own client is registered with `opencode mcp add --global <name> --env KEY=value --
<command…>`.

## Attachments

Bloom names an attachment by its path inside the prompt text, as for every backend. Measured with
an image at `.bloom/attachments/x/img.png`: the `read` tool read it without a permission question
and a vision model named its colour. The tool result carries the image as a base64 content block,
which Bloom does not store.

## Sign in and credentials

Credentials live in OpenCode's SQLite database under the data directory, not in a file Bloom
could read without opening that database. Bloom therefore shows no account for OpenCode. Whether
it has a provider at all is asked the way a chat would ask it: detection opens a session in a
scratch directory and deletes it (`OpenCodeProviderCheck`). `CatalogNotReady` shows OpenCode as
installed but not connected; any other failure learns nothing and leaves it connected, which a
stock install is, because it has hosted models that need no account. Signing in is
`opencode auth login`, run by the user.

Measured on 2026-11-19 with Ollama as the only provider (`disabled_providers: ["opencode",
"lmstudio"]`, `OPENCODE_DISABLE_FREE_MODELS=1`): `session/new` right after `initialize`
succeeded in twenty runs out of twenty and listed `ollama/qwen3.5:4b` every time. A local
provider detected late is therefore not read as none; it is only missing from the list, as
"Discovering models" says.

Global configuration is the directory `~/.config/opencode/` (`opencode.json` or `opencode.jsonc`).

## Left out, and why

- **Quotas and usage limits.** ACP carries none. The only source seen is the experimental HTTP
  route for OpenCode's own subscription, which says nothing of a provider's quota.
- **Several accounts.** Isolating OpenCode's sign in means moving its data directory, and the
  session history lives there too.
- **The automatic router.** It needs a small reliable model per backend, and OpenCode's depends on
  which providers the user connected.
- **Image content blocks, `session/list`, `session/fork`, `session/load`.**

Measured but not wired yet: steering (above).
Not measured: subagent updates (`_meta["opencode/child-session-updates"]`), `elicitation/create`,
and whether `opencode -s <id>` opens an ACP session in the terminal interface.

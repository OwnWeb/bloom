# The automatic router

Off by default. Settings, Models, Automatic router turns it on. With it on, a new workspace's first
chat does not start on whatever model the window happened to be set to: a light model reads the
task first, and Bloom picks the model and reasoning effort from what it says.

It works on every agent Bloom runs a chat on (Claude Code, Codex, Grok) and only with agents that
are signed in. It never moves a chat to another agent: a Codex chat is routed among Codex models.

## What happens when Create is pressed

```
Create ──▶ AppModel.startWorkspace
             ├─ openingRouter(for:)        who reads the task, and with which table
             ├─ OpeningRoute(...)          the analyser starts reading now, streaming
             ├─ WorkspaceManager.start     worktree cut, session row written
             └─ startSetupThenSend(route:)
                  ├─ route.settle(into:in:) joins the question to the new chat
                  ├─ opening message queued (pending bubble: "Goes once a model has been chosen.")
                  ├─ setup script runs, as before
                  └─ await route.settled()  answer written with updatePreferences, then the
                                            one drain, after setup, as it always was
```

The analyser is asked before the worktree exists, so most of its wait is spent behind git and the
setup script. Only the opening message waits; nothing else about the workspace does.

While it waits, a card over the top of the conversation shows a spinner, the analyser's thinking as
it is written, and a Skip button. Once settled it says what was chosen and why, until the first row
of the conversation arrives.

## Signed in, not just installed

"Connected" is `AgentStatus.Connection.connected`: the CLI is found and an account is configured.
Claude Code: `~/.claude.json` or `ANTHROPIC_API_KEY`. Codex: `~/.codex/auth.json`. Grok:
`~/.grok/auth.json` or `XAI_API_KEY`. The check is local, so an expired token still counts, and the
call then fails like any other failure: the chat keeps what the window was set to. Cursor and
OpenCode are never connected, because Bloom does not read their accounts and has no runner for them.

`AgentAvailability` holds the answer for the app. It detects at launch, takes over whatever the
Agents pane detects, and the create window asks again when the last answer is five minutes old.

## Who reads the task

`RouterAnalyser.resolve`, in the core:

1. A named agent, from Settings, while it is signed in.
2. Otherwise the chat's own agent, while it is signed in.
3. Otherwise the first signed in agent, in the order Claude Code, Codex, Grok.
4. Otherwise nobody, and the create window offers no checkbox.

On that agent, the model the owner chose in Settings while the list still offers it, otherwise the
suggestion: Haiku on Claude Code, the newest reduced model (`mini`, `nano`) on Codex, the newest
`fast` or `mini` model on Grok. The effort is the lightest that still thinks: `low` before `minimal`.

| Agent | Adapter | How it is kept away from the code |
|---|---|---|
| Claude Code | `ClaudeRouterAsk`: `claude -p`, stream-json, `--json-schema` | no tools at all, no MCP, safe mode, no session saved, empty folder |
| Codex | `CodexRouterAsk`: one thread on a short-lived app-server | read-only sandbox, `untrusted` approvals all declined, empty folder |
| Grok | `GrokRouterAsk`: one prompt on a short-lived ACP connection | plan mode, permissions refused, empty folder |

Codex and Grok cannot be run with no tools at all, and both start the owner's own MCP servers.
Settings says so, and the card only says "not your code" for Claude Code.

Codex is on `untrusted` rather than `never` because `docs/CODEX.md` measured a read-only sandbox
running reads and commands without a single question: under `never` an analyser could read any
file the owner can by absolute path. `untrusted` asks about nearly every command, reads included,
and every question is declined. Grok's plan mode is the strictest mode Bloom can send it, and it is
a research mode, so Grok may still read a file without asking. Neither has an output schema Bloom has measured, so the prompt asks for the JSON in
words and `ModelRouterProgress` reads it out of the answer's text.

## Which model the chat gets

The analyser answers one of five rungs and a reason. It never names a model.

| Rung | Claude Code | Codex and Grok |
|---|---|---|
| trivial | haiku, low | light model, low |
| simple | sonnet, medium | light model, medium |
| moderate | sonnet, high | full model, medium |
| complex | opus, high | full model, high |
| deep | opus, extra high | full model, extra high, else high |

Claude Code's table is written down (`ModelRouterTable.standard`), because its aliases always
resolve. Codex's and Grok's are read off the list each agent last answered with
(`ModelRouterTable.suggested`), the light model being the newest reduced one and the full model the
most capable. An account with no light model runs every rung on the full one. `max` and `ultra` are
on no rung: they can turn a quick answer into a quarter of an hour, and that should be somebody's
decision rather than a classifier's.

Every rung can be changed in Settings, per agent, and Reset puts it back on the suggestion. Only the
changed rungs are stored, so a suggestion goes on improving as the lists do.

`ModelRouting.route` then narrows:

- Claude Code: the owner's own variant of the same family is kept (`opus[1m]` stays `opus[1m]`), and
  a family the account does not offer keeps the window's model.
- Codex and Grok: an id the list no longer offers keeps the window's model.
- An effort the model does not take lands on the model's own default, and a model with no levels
  is sent none.

## Who wins

A model or effort picked by hand in the window: picking one unticks the router's checkbox. The
checkbox can be ticked again to hand the choice back.

## Why the hold is not a `DeliveryHold`

`DeliveryHold` is read off stored rows by the bridge's tools as well as by the transcript. The
router's wait lives in memory for a few seconds after Create and cannot outlive the process that is
having it, so `TranscriptModel` asks `OpeningRoute.holds(_:)` beside the hold instead of widening
the enum.

## The prompt

Editable in Settings, Prompts, as "Choose a model for a new workspace". It may change how tasks are
sorted; it cannot change the rungs. On Claude Code a schema holds them to the five above, and on
Codex and Grok an answer naming any other rung is no answer at all.

## Not measured yet

- Whether Codex sends reasoning deltas without a `summary` setting on the turn, and whether its
  app-server takes `ephemeral` on `thread/start` and `outputSchema` on `turn/start`. Until then a
  router thread can appear in Codex's own history, and the card may show only its spinner.
- Whether Grok sends thought chunks at a low effort.

## Not done yet

- Only the create window routes. A `bloom://` link, the Services menu and a Shortcut have no window
  to draw the card in, and the bridge and Carry On name their own controls.

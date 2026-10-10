# The automatic router

Off by default. Settings, Models, Automatic router turns it on. With it on, a new workspace's first
chat does not start on whatever model the window happened to be set to: Claude Haiku reads the
task first and Bloom picks the model and reasoning effort from what it says.

## What happens when Create is pressed

```
Create ──▶ AppModel.startWorkspace
             ├─ OpeningRoute(...)           claude -p --model haiku, streaming, starts now
             ├─ WorkspaceManager.start      worktree cut, session row written
             └─ startSetupThenSend(route:)
                  ├─ route.settle(into:)    joins the question to the new chat
                  ├─ opening message queued (pending bubble: "Goes once a model has been chosen.")
                  ├─ setup script runs, as before
                  └─ await route.settled()  answer written with updatePreferences, then drain
```

The router is asked before the worktree exists, so the eight to seventeen seconds the namer
measured for the same invocation are mostly spent behind git and the setup script. Only the
opening message waits; nothing else about the workspace does.

While it waits, a card over the top of the conversation shows a spinner, Haiku's thinking as it is
written, and a Skip button. Once settled it says what was chosen and why, until the first row of
the conversation arrives.

## Decisions, and where they live

| Question | Answer | Where |
|---|---|---|
| Does this workspace ask? | Bloom chat, Claude Code, something written, not Carry On, setting on, checkbox on | `ModelRouting.shouldRoute` |
| What does Haiku answer? | One of five rungs and a one sentence reason, forced by `--json-schema` | `ModelRouter.jsonSchema` |
| Which model is that? | A fixed table, never a model id from the model | `ModelRouterTable.standard` |
| What if the account lacks it? | The model the window was set to stays | `ModelRouting.route` |
| What if the effort does not fit? | The model's own default effort, or none for Haiku | `ModelRouting.route` |
| Who wins, a hand pick or the router? | The hand pick: choosing a model or effort in the footer unticks the box | `ModelRouting.takesOver` |
| What does the card say? | Every sentence | `ModelRouteCaption` |

The table:

| Rung | Model | Effort |
|---|---|---|
| trivial | haiku | low |
| simple | sonnet | medium |
| moderate | sonnet | high |
| complex | opus | high |
| deep | opus | extra high |

`max` is on no rung on purpose: it can turn a quick answer into a quarter of an hour, and that
should be somebody's decision rather than a classifier's.

## Why the model is never asked for a model

Haiku cannot know which models this account has or what the owner is willing to pay for, and a
model id it invented would reach the CLI one step later, where a first turn fails with "There's
an issue with the selected model" and nobody is watching. A fixed vocabulary in and a fixed table
out is what lets the suite pin the route down.

## Why the hold is not a `DeliveryHold`

`DeliveryHold` is read off stored rows by the bridge's tools as well as by the transcript. The
router's wait lives in memory for a few seconds after Create and cannot outlive the process that
is having it, so `TranscriptModel` asks `OpeningRoute.holds(_:)` beside the hold instead of
widening the enum.

## The prompt

Editable in Settings, Prompts, as "Choose a model for a new workspace". It may change how tasks
are sorted; it cannot change the rungs, which the schema holds to the five above.

## Not done yet

- The table is fixed. Making it editable is a Settings pane and a stored value, no new logic.
- Only the create window routes. A `bloom://` link, the Services menu and a Shortcut have no
  window to draw the card in, and the bridge and Carry On name their own controls.
- Fable is in no rung. Adding it to `deep` is one line, once it is offered to every account the
  router might run on: `ModelRouting.route` already falls back when a family is missing.

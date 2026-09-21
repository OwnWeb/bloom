# What the Mac's interface offers, for the web to port

Written for the web client, which has been building against a composer nobody had written down.
Every control the Mac's conversation surface has, what it does, where its state lives, whether a
Cloud workspace has it at all, and what the wire would need for the web to have it.

**How to read the confidence marks.** Every entry is one of two things:

- **[checked]** read in the code while writing this, with the file named.
- **[unsure]** believed but not verified here. Check before building on it.

Nothing in this document is recalled without a mark. **Outside the transcript section, one
`[unsure]` remains, and it is a real unknown rather than an unread one**: whether a running machine's `result` rows carry the payload
the context gauge parses, which only a live machine can answer. A confident wrong entry costs the web more
than an honest "unsure", which is the whole reason the marks are here.

**And one mark that covers the whole document: none of this was seen.** It describes what the code
does, not what the window looks like. A conversation row and a terminal are drawn through AppKit,
so an offscreen render gives SwiftUI's placeholder rather than the view, and a capture of a real
window needs the display, which belongs to whoever is sitting at it. **Everything here is read
rather than observed**, including the places where it says how something reads to a person.

## The composer's footer, left to right

`Sources/Bloom/Views/Center/Composer/ComposerFooterView.swift` is the row. It is written against
`ComposerControls` rather than against a session, because the create window draws the same row
before any session exists. **[checked]**

The row drops things as the pane narrows, in a fixed order: first the words beside the picker
glyphs, then the context reading. The centre column can be dragged to 420 points and split again,
and at that width the full row does not fit; left to overflow it clipped from both ends at once and
took the send button off the screen. **[checked]** The create window does not adapt, because its
width is fixed and was measured against the full row.

### 1. The settings picker: "Opus 5 · High" with a chevron

`ComposerSettingsPicker`. One menu carrying five choices: **model**, **reasoning effort**, **output
style**, **permission mode**, and, on backends that have one, **interaction mode**. Codex also gets
a **context window** size. **[checked]**

- **State**: `ComposerControls` (`Sources/BloomCore/Agent/ComposerControls.swift`), fields `model`,
  `effort`, `permissionMode`, `interactionMode`, `isFastMode`, `codexFastMode`, `outputStyle`,
  `codexContextWindow`, `hasWorktree`. **[checked]**
- **Survives a launch, locally**: yes, by two different roads. **[checked]**
  - **Model, effort, agent, permission mode, interaction mode** go through
    `ComposerSessionEditor.apply` to `TranscriptModel.updatePreferences`, which writes the session
    row (`Store.updateSessionPreferences`).
  - **Fast mode, Codex fast mode, output style, Codex context window** are written straight to
    `Store.setSetting` under per-session keys by `ComposerView.apply(controls:)`.
- **Cloud**: the wire carries all nine. `ComposerControlsRecord` has `agent`, `model`, `effort`,
  `permissionMode`, `interactionMode`, `fastMode`, `codexFastMode`, `outputStyle`,
  `codexContextWindow`, and `set_composer` writes them. A chat that does not exist yet takes
  `composer_defaults` off the workspace snapshot. **[checked]**
- **The Mac used only five of the nine on a Cloud chat until this was written, and it was a bug,
  not a design.** **[checked]** The other four were seeded in `ComposerView.prepare()` after a
  `guard transcript.cloud == nil else { return }`, so a Cloud chat started them at this Mac's
  defaults, and a change to only those four failed the guard in `apply(controls:)` that decided
  whether to call `updatePreferences`, so `set_composer` was never sent. The lightning bolt showed a
  local default and pressing it reached nothing. **Fixed on this branch**: the four are read from
  the machine when the chat is prepared and whenever the machine's controls change, and every
  change sends all nine through `TranscriptModel.setCloudControls`, putting the four back if the
  machine refuses.
- **Wire needed**: none. **Round-trip all nine through `set_composer`**, which is what the Mac now
  does.
- **Shortcut**: none.

**The lists themselves are not on the wire, and that is the catch.** Which models exist comes from
`ComposerModelCatalog` and, for Codex, from a subprocess; output styles are read off the checkout's
`.claude/output-styles`; the permission modes are `controls.permissionModeChoices`, which is a pure
function of the backend. **[checked]** So the web can round-trip the *chosen* values today, and to
populate the menus it needs either its own copy of the catalogue or a new call. **The permission
modes and the efforts are derivable from the agent name and need nothing.** **[checked]**

### 2. The lightning bolt: fast mode

`ComposerFastModeToggle`. **[checked]**

- **What it is**: Claude's fast mode, and for Codex a separate `codexFastMode` with a measured
  speed reading beside it (`CodexSpeed.read`, a subprocess against the project). **[checked]**
- **Cloud**: the flag is on the wire (`fastMode`, `codexFastMode`). **The Codex speed reading is
  not**, and it is read by running something locally, so the web cannot have that half without a
  new call. **[checked]**
- **Wire needed**: nothing for the toggle. For the speed reading, a field on the composer record or
  a call of its own, and it is worth asking whether it earns one.
- **Shortcut**: none.

### 3. "54%": the context gauge

`ComposerContextGauge`, with `ContextWindowDetail` in a popover. **[checked]**

- **What it is**: how much of the model's context window the conversation is using. A reading
  rather than a control, which is why it sits across the spacer from the pickers.
- **State**: `TranscriptModel.contextUsage`, folded from the transcript's own rows by
  `ContextWindowUsage.updated(_:with:)`. Nil until a turn has finished, deliberately: a gauge
  reading 0% would be a claim. **[checked]**
- **Cloud: the gauge did not appear until this was written, and the reason was on the Mac.**
  **[checked]** `contextUsage` was only moved by `noteContextWindow`, which only the local read path
  called; `receiveCloud` absorbed a machine's rows without asking, and its rebuild set the rows
  without the reading. **Fixed on this branch**: arriving rows are folded, and a whole history read
  takes the reading from the whole of it, as `load()` does locally.
- **Whether it would work once computed** depends on a machine's `result` rows carrying the payload
  `ContextWindowUsage` parses. **[unsure]**, and genuinely so: this is a question about what a
  running machine stores, which the code here cannot settle. It is moot until the call exists.
- **Wire needed**: probably none. For the web, fold the reading from `result` rows as they arrive,
  and check the first one against a live machine.
- **Shortcut**: none. The popover opens on click.

### 4. The prompt-list icon: quick prompts

`text.badge.plus`, opening `QuickPromptMenu`. **[checked]**

- **What it is**: saved prompts, inserted into the box. Two sources in one panel: **the owner's
  own**, which live in Bloom's database and are editable from the panel, and **the project's**,
  read from the checkout's settings file. **[checked]**
- **State**: the owner's in `Store` through `QuickPromptCatalog`; the project's in
  `model.settings.quickPrompts`. **[checked]**
- **Cloud**: the owner's own work, because they are this Mac's. **The project's do not**, because
  the panel gets them from the workspace model and a Cloud chat has none. **[checked]**
- **Wire needed**: for a project's own prompts, a field or a call carrying what the machine's
  checkout declares. **This is the one composer feature that is missing rather than merely
  unported.**
- **Shortcut**: none.

### 5. The turn-down arrow: a side conversation

`arrow.turn.down.right`, help text "Ask a side question (/btw)". **[checked]**

- **What it is**: a question asked beside the main thread without disturbing it.
- **Cloud**: **no**, and it is drawn only when there is a workspace model, so it is absent rather
  than disabled in a Cloud chat (`canOpenSideConversation` requires `model != nil`). **[checked]**
  `WorkspaceSurface.chatLayer` is the seam: a local workspace hangs its side conversations there
  and a Cloud one draws nothing. **[checked]**
- **Wire needed**: a real feature on the machine, not a field. Lowest priority of anything here.
- **Shortcut**: none on the button, and **`/btw` in the box does the same**. **[checked]** It is a
  built-in slash command (`SlashCommandIndex`: "Ask a side question while the main agent works"),
  and pressing Return with a `/btw …` draft opens a side conversation instead of sending
  (`ComposerView.send()` asks `SideConversation.question(in:)` first). In a chat with no workspace
  model it sends nothing and says why: in Ask Bloom "Use /btw in a workspace chat to open a side
  conversation.", and in a Cloud chat "Side conversations are not available in a Cloud workspace
  yet." The first sentence used to be given to both, which sent somebody standing in a workspace
  chat off to look for one.

### 6. The paperclip: attachments

- **What it is**: files carried with the turn, drawn as chips above the text and in the sent bubble.
- **Cloud**: **yes**. The bytes cross when the turn does, through `upload_file`, and the machine
  says where it put them; everything above that, the chip, the undo, the sentence, is the same code.
  **[checked]**
- **Wire needed**: none.
- **Shortcut**: none.

### 7. The filled square: Stop

`stop.fill`, `ComposerStopButton`, drawn only while a turn is running. **[checked]** This is the
"filled square" in the picture, which means the screenshot was taken mid-turn.

- **Cloud**: yes, the `stop` operation. **[checked]**
- **Wire needed**: none.
- **Shortcut**: **Cmd+.**, the Workspace menu's **Stop Agent**. **[checked]** It stops the chat
  whose composer has focus, falling back to the highlighted workspace's active chat
  (`BloomCommands`, `MenuCommand(.stopAgent)`), and calls `TranscriptModel.stop()`, which on a Cloud
  chat is the machine's `stop`. **[checked]** The fallback used to read only a local
  `WorkspaceModel`, so on a Cloud chat it worked while the composer had focus and did nothing once
  focus moved; it asks the Cloud workspace's chat in front as well now.

### 8. The send arrow

`arrow.up`, `ComposerSendButton`. **[checked]**

- **It never moves and is never disabled by something being busy**, only by there being nothing to
  send. It is the last control in the row in every state, which is what makes it the thing the hand
  finds. **[checked]**
- **Queueing**: a message typed while a turn is running joins the chat's queue rather than being
  refused, and the button says so in its tooltip rather than changing. Whether the next message
  queues is `TranscriptModel.queuesNextMessage`, which is the same function `submit` asks.
  **[checked]**
- **Cloud**: yes. The queue is the machine's and arrives as `queue` events. **[checked]**
- **Shortcut**: **Return**. **[checked]**

### Not in the chat composer: the CLI toggle

The `terminal` glyph toggle exists in `ComposerFooterView` but only the **create window** passes
`usesCLIChat`, so it is not in a conversation's footer at all. **[checked]** Worth knowing so the
web does not port a control the Mac does not show.

## The composer above the footer

- **Mentions.** `@` at the head of a message means a person in a shared workspace and a file
  everywhere else; the rule is `MentionAddress.offersPeople` in the core, and the web already has
  its own copy of this. **[checked]**
- **Slash commands.** `SlashCommandCatalog.load(workspacePath:)` reads them off a path on disk, so
  they are **local only** and there is nothing on the wire for them. **[checked]**
- **Review comments** ride with the next message as chips. Cloud has them. **[checked]**
- **The draft.** Saved per session through `Store.saveDraft`, **and a Cloud chat's is kept in this
  Mac's database too**, because a draft is not the machine's: it is what this person has typed and
  not sent. It used to be dropped, because `store` answers nil for a Cloud chat and `saveDraft`
  returned at its first line. **[checked]**

## The terminal, on both sides

**Answering the question properly rather than yes or no.**

**The Cloud app has one terminal per workspace, and that is all it has.** **[checked]**

- It is made the first time the pane is shown and kept with its scrollback for as long as the
  workspace is open (`CloudWorkspaceSession.terminal`, a lazy `CloudTerminal`). **[checked]**
- **One per person, not one per workspace**: the shell's name is derived from the reader's account
  id (`TerminalSocket.name(for:)` → `shell-<id>`), so two collaborators get their own shell with
  their own keys rather than typing into each other's. **[checked]**
- It closes when the workspace is suspended or closed. **[checked]**
- There is **no second terminal, no naming, no split and no persistence across a launch** on the
  Cloud side's *client*. **[checked]**
- **The machine keeps the shell when the socket drops.** **[checked]** `RemoteTerminals` holds tmux
  sessions on a private socket beside the database, and its own doc says it: **"A session outlives
  every attachment to it; only `close(name:)` or `shutdown()` ends a shell."** So a dropped
  connection reattaches to the same shell and the machine redraws it; a workspace restarting ends
  it. This is from this branch's copy of the machine's code, which is what machines will run once
  they update; deployed machines run the release they are pinned to.
- **And the machine already keeps several named terminals**, up to 32 attachments, each recording
  who opened it (`@bloom_owner`). **[checked]** So what the Cloud client lacks is the interface, not
  the protocol: the Mac simply asks for one name per person.

**What the Mac has around a local terminal, and the Cloud app does not:**

- **Several terminals**, as tabs in the strip, each its own shell. **[checked]**
- **Naming them**, from the tab's context menu and its accessibility rotor. **[checked]**
- **Splitting a terminal tab** into panes, with a layout tree per tab, focus, and zoom
  (`TerminalSplitStore`, `SplitLayout`). **[checked]**
- **Persistence across a launch**, behind a Settings switch that is **off by default**, using a
  private tmux server on Bloom's own socket so the user's own tmux is untouched
  (`TerminalPersistence`, key `terminal.persistSessions`). **[checked]**
- **Run scripts** get terminal tabs of their own, with the project's declared commands.
  **[checked]**

So the honest answer to "is there already a terminal in the cloud app" is: **yes, one, and it is
the shell rather than the terminal experience.** Everything the Mac has around it is missing on
both clients.

## Outside the composer, worth porting and easy to miss

- **The tab strip.** Chats, terminals, browsers, the review, the notes, and run scripts, in one
  strip, reorderable, with the `+` menu on the right. The Mac's shortcuts for these are in
  `Sources/BloomCore/Presentation/MenuBarCatalogue.swift`, which is one array and is the source of
  truth. **[checked]**
- **Panes and splits.** Already sent to the web separately and built there.
- **The inspector's tabs**: Changes, History, and the pull request. `WorkspaceSurface` lists them
  per workspace (`availableInspectorTabs`). **[checked]**
- **Recently closed chats**, offered back from the `+` menu. Local workspaces read their store and
  Cloud workspaces use the machine's bounded `recently_closed` and `reopen_chat` operations. Both
  feed the same menu and the same `SessionReopening` wording. **[checked]**

## The transcript: groups, the opening line, the working line, the footer

Written for the web to port the Mac's transcript rather than rebuild it from a screenshot. **The
same caveat as the rest of this document, and more so here: none of it was seen.** The rows are
drawn in an AppKit table, so an offscreen render gives placeholders, and this describes the code.
Where Freek's screenshot and the code seem to disagree it says so rather than choosing.

**Where the decisions live.** The grouping is a pure function in the core, with tests, and the web
should port that rather than the view:

- `Sources/BloomCore/Transcript/TranscriptFold.swift`: `TranscriptFold.folds(in:extending:)`
  builds the groups, `TranscriptFold.hiddenIndices(_:revealed:drawn:)` decides what a collapsed
  group hides, `TranscriptFold.refoldedAtLiveEnd(_:in:)` decides when an opened group closes
  itself again, and `TranscriptFold.Fact` is the only thing it reads about a row. Its header is the
  full rationale and is worth reading whole. **[checked]**
- The tests are the cases to share: `Tests/BloomCoreTests/TranscriptFoldTests.swift`,
  `TranscriptFoldErrorTests.swift`, `TranscriptFoldQuestionTests.swift`,
  `TranscriptFoldAdoptionTests.swift` and `TranscriptFoldCacheTests.swift`. **[checked]** that they
  exist; what each case covers is in the files.
- How a stored row becomes a `Fact` is `TranscriptRow.foldFact(seq:isFresh:)` at the top of
  `Sources/Bloom/State/TranscriptModel.swift`. **[checked]**
- A tool call's one line (glyph, label, detail, colour role, chips) is
  `ToolPresenter.present(name:input:worktree:)` in `Sources/BloomCore/Agent/ToolPresenter.swift`,
  returning a `ToolPresentation`. Also pure, also in the core. **[checked]**
- The turn's end is `TurnEnding.of`, `TurnDuration.wholeSeconds`, `TurnFailure.of` (all in
  `Sources/BloomCore/Agent/`) and `TurnAnswer.text` (`Sources/BloomCore/Transcript/`). **[checked]**

### What makes a group

**Consecutive grey activity folds into one group, and anything a person should read breaks it.**
`Fact.isActivity`: **[checked]**

- **Activity, which can fold:** tool calls, thinking, permission asks, and `system` rows that draw
  something (the "Started with" line, a compaction boundary). Rate limit notices and hook events
  are dropped before this, so they neither fold nor break (`TranscriptNoise`).
- **Boundaries, which never fold:** a user's message, a crew message (another agent talking),
  assistant prose, and the turn's `result` row. A background task's notification that opened a
  turn is a boundary too (`Fact.opensTurn`).
- **Prose closes the group above it as "answered", and activity after the prose starts a new
  group.** So one turn with prose in the middle is two groups, and the prose stays between them.
- **Things that stay visible and split the group in two, without breaking the turn:** an `error`
  row (the agent process dying), a question card (`AskUserQuestion`), an inline image (a
  `media_show`, or Codex's image viewer), and a message sent with `workspace_say`. Answered questions too. The activity either
  side becomes two separate groups (`Fact.mustShow`, and the loop in `close(hasAnswer:)`).
- **A failed tool call does not split a group, on purpose.** It used to, and a run came out as "7
  actions", error, "42 actions", error. It folds like any other call, and the collapsed line gives
  no sign that it hides one. The header's rule 2 says why.
- **A long pause does not break a group.** Nothing in the fold reads time, apart from the one
  second described below.

**Sizes.** A group gets its entry in the list from 2 rows (`leastWork`), but only draws a line and
hides anything from 3 hidden rows (`leastHidden`). With fewer than three to hide, the rows are
simply shown and no group line is drawn. **[checked]**

**What a collapsed group still shows** (`hiddenIndices`): **[checked]**

- **A tool call whose result has not come back stays visible below the group line**, and completed
  calls after it still fold. Except that **a call younger than one second folds as though it had
  settled** (`freshCall`), so quick reads and greps never flash up as their own row and jump into
  the count. Only a call still running after a second is drawn on its own.
- **A permission ask nobody has answered is never hidden**, however new.
- **A row the reader opened, or navigated to** (a search hit, the row a session was opened on)
  stops the fold there: rows from it onwards stay visible.

**A running group stays folded while it grows**, with the count going up. If the reader opened a
group that is still live and another row arrives while they are at the live end, **it folds itself
again** so the newest row stays in view. Scrolled away from the end, their open group stays open
(`refoldedAtLiveEnd`). **[checked]**

**Subagents are one row.** Every row a subagent produces (tools, thinking, its prose) leaves the
list. The `Agent`/`Task` call that started it stands for all of it and shows "· 42 actions"
after its description, counted the way a group counts. What still surfaces from inside a subagent,
indented under a hairline: a question it is stopped on, an image it showed, it dying, a row the
reader navigated to. Clicking the call's title opens the subagent's own pane; its chevron opens the
brief and the result. **[checked]** (`Folds.absorbs`, `Folds.actions(underCall:)`, `ToolRowHeader`)

**The group line itself** (`Sources/Bloom/Views/Transcript/TranscriptFoldRowView.swift`): a
disclosure chevron, then **a plain "N actions" caption** in the same secondary ink and regular
weight as the turn's completion metadata. Nothing else: no badge, tool names, durations or failure
mark. Collapsed, the number is how many rows it hides; opened, it is how many rows the group has.
The whole line is the toggle. **[checked]**

**Opened**, the rows are drawn in place under the line, each as its own row, exactly as they would
be with no group. There is no separate "expanded group" design. **[checked]**

### The "Started with" line

`Sources/Bloom/Views/Transcript/SessionStartRowView.swift`. A bolt glyph (`bolt.horizontal.circle`),
"Started with" in secondary ink, then **two chips: the model and the permission mode**, each shown
by the name the composer's own pickers use (`ComposerOption.label`, `PermissionMode.label(on:)`),
so "Opus 5" and "Bypass permissions" rather than `opus-5` and `bypassPermissions`. A chip is left
out when its value is empty. **[checked]**

**When it appears: at every turn, not once per session.** The CLI writes a `system`/`init` line
at the start of every turn, and each one is stored and drawn. Checked against a copy of the Bloom
Dev database: every user row is followed by an init row. **[checked]**

**How it groups: it stands above the turn's group, never inside it**, in a local workspace and a
Cloud one alike. **[checked]** The fold holds it out the way it holds out an image or a question
(`Fact.featured`, set by `foldFact` from `TranscriptRowInk.isSessionStart`), so a turn reads
"Started with", then "N actions" for the work, then the prose. The shared case is
`sessionStartStandsApart` in `TranscriptFoldTests.swift`.

This was Freek's screenshots made the rule. Before it, a Cloud workspace did it by accident and a
local one folded the line away: a Cloud row's JSON was re-encoded with sorted keys, which pushed
`"subtype":"init"` past the bytes the row test reads. Cloud rows are now re-encoded with the keys
every row test depends on (`type`, `subtype`, `id`, `name`) where the CLI writes them
(`CloudPayloadBytes`), so the same tests answer the same way for both kinds of workspace.

### The working line

`Sources/Bloom/Views/Transcript/StreamingRowView.swift`, drawn at the foot of the transcript
while a turn runs and nothing is streaming yet. **[checked]**

- **The glyph is the pulsing running dot** (`ActivityDot`, `Palette.running`, the blue), and the
  text beside it is in secondary ink rather than blue.
- **The text is the CLI's own status**, first letter capitalised, with "requesting" rewritten to
  "Waiting for model". Before any status: "Working" once the agent is running, "Starting" while the
  message is still being sent. "Waiting on you" when a permission ask is open.
- **While a tool is streaming its call**: a gear glyph in running blue and "Running" plus the
  tool's readable name, so an MCP call reads "Running Bloom: workspace say" rather than the wire
  name (`MCPToolName.readable`).
- **Compaction** gets a breathing glyph in tertiary ink instead of the blue dot, because it is
  housekeeping rather than work for you.
- **A retry run replaces the line** with the retry row.
- **Once text or thinking streams in, the line goes** and the streaming prose or thinking takes its
  place, in the same columns the stored row will use, so nothing moves when it is saved.

### The end of a turn

`Sources/Bloom/Views/Transcript/TurnFooterView.swift`, drawn in place of the `result` row.
**[checked]**

- Whitespace rather than a rule separates the response from the completion metadata.
- **The duration**: "Completed in 9s", "Failed after 1m 4s", "Stopped after 12s". Whole seconds,
  then minutes and seconds (`TurnDuration.wholeSeconds`).
- **No mark for an ordinary finish.** A glyph appears before the duration only for the other three
  endings: a raised hand in warning colour for "calls were denied", a red exclamation for failed, a
  stop symbol in secondary ink for stopped (never red, since nothing went wrong).
- **The files the turn changed**, as chips with the counts, as many as fit (up to six, then fewer,
  then "3 files"), with "+N more".
- **A quiet copy button, "Copy this answer"**, sits at the right of the final response and copies
  the turn's answer text (`TurnAnswer.placement`). It keeps a normal keyboard and accessibility
  target while drawing its symbol one scale smaller than the ordinary copy control.
- Under the line, only when there is something to say: what denied calls mean and which setting
  denied them, the CLI's own words for a failure (prefixed "The agent said:"), what the agent left
  running in the background, and a note that the turn recovered from retries.
- Cost is deliberately not shown.

### Tool rows by kind

One line each, closed by default: **glyph, label, detail, chips, then an outcome word and the
duration at the right** (`ToolRowHeader`). The label is secondary ink, the detail tertiary and set
in monospace only when it is a literal (a path or a command). The glyph takes the row's colour role
(`ToolTint`: neutral, accent, positive, negative, warning), or red when the call errored and
amber when it was refused. The outcome word is "error" in red, or the refusal's label in amber. The
duration is short: "340ms", "2.4s". **[checked]**

The label and glyph per tool are in `ToolPresenter.shape`, and the common ones are: **[checked]**

| Tool | Glyph | Label | Detail and chips | Colour role |
| --- | --- | --- | --- | --- |
| Read | `doc.text` | "Read", or "Read 40 lines" | file name; chips for the file, "from 120", pages | accent |
| Write | `square.and.pencil` | "Write" | file name; file chip, "86 lines" | positive |
| Edit, MultiEdit | `pencil.line` | "Edit" | file name; file chip | positive |
| Bash | `terminal` | the description Claude writes for the command, else "Bash" | the command on one line, a leading `cd` into the worktree hidden; a "background" chip | neutral |
| Glob | `magnifyingglass` | "Find files" | the pattern | accent |
| Grep | `text.magnifyingglass` | "Search" | the pattern | accent |
| Agent, Task | `person.2` | "Agent: type" | the description, then "· N actions" | warning |
| TodoWrite | `checklist` | "Todos" | | neutral |
| WebFetch, WebSearch | `globe`, `magnifyingglass.circle` | "Fetch", "Web search" | | accent |
| anything unknown, MCP tools | `wrench.and.screwdriver` and others | a readable name | | neutral |

**Opened**, a row shows its input then its result (`ToolDetailView`, `ToolInputView`,
`ToolResultView`): **[checked]**

- **Bash**: the command in a code block with a copy button, chips for timeout and "runs in the
  background", then the output.
- **Edit and MultiEdit: a before and after of each replacement** (`ToolReplacementView`), not a
  unified diff.
- **Write**: the path, then the whole content in a code block tinted with the diff's added colour.
- **Read**: the path, then the output.
- **Grep, Glob**: the pattern in a code block, chips for "in path", "matching glob" and the output
  mode.
- **Agent, Task**: the description and the brief as prose with "Copy the brief"; the run itself
  opens in its own pane.
- **TodoWrite**: the todo list drawn as a list. **ExitPlanMode**: the plan as prose.
- **Anything else**: the input as pretty-printed JSON.
- **The result** is monospace, secondary ink (red for an error), behind a thin rule on the left, cut
  at 500 lines with a "Show all" / "Show less" link (`TextCap.lineCap`, `TextFold.title`).
- **A refusal** replaces the result with a sentence saying why and what would allow it.

**Thinking** is its own row: a sparkle glyph, "Thinking" in italic, and the first line of the
thinking in tertiary italic while closed; opened, the whole text. It is activity, so it folds.
**[checked]** (`ThinkingRowView`)

**Rows that are content rather than activity**: a successful `media_show` is drawn as its caption
in body prose, the image or video, then its path in tertiary caption ink with a photo or film
icon and a small menu (Open, Download). It never folds, and it splits a group. **[checked]**
(`MediaShowRowView`) **In a Bloom Cloud workspace the picture is the machine's `media` row, not the call**:
the Mac fetches the copy it names with `download`, keeps it in its caches by workspace, and draws
it through the same view, with the file's `name` under it. The machine's `media_show` call is then
an ordinary tool row that folds (`CloudMediaRowView`, `TranscriptHome.drawsMediaFromCalls`,
`foldFact(picturesFromCalls:)`). The shared fold case is `mediaRowSplits`. **[checked]** in code,
not yet seen against a machine. A `workspace_say` that sent something is drawn as the message
it sent, a bubble headed "To" the workspace, and **it never folds and splits a group like an
image does** (`WorkspaceSayRow.isCall`, read by `foldFact`). **[checked]** It used to fold into "N
actions" while a comment said otherwise; the fold was the one that was wrong, because its own
rule 2 keeps conversation content on screen.

### What is remembered

**[checked]** (`TranscriptListView`, `TranscriptPaneMemory`)

- **Which groups the reader opened and which tool rows they opened are remembered per session for
  as long as the app is running**, so a tab switch or looking at the changes and coming back does
  not close them. Keyed by the sequence number of the group's first row, and by the row.
- **Not across a relaunch**, on purpose: reopening a workspace should not restore forty open rows.
- **A new turn does not close anything the reader opened in an earlier turn.** Only a live group
  the reader opened closes itself, and only while they are at the live end (above).
- The reading position is remembered the same way, alongside.

**Whether a Cloud transcript is drawn by the same code**: it is the same `TranscriptListView` over
the same row kinds, and the difference that was found (a Cloud row's JSON re-encoded with sorted keys,
so the row tests read it differently) is fixed at the source: see "Started with" above. A machine does send the init row: Freek's Bloom Cloud
screenshots show it. **[checked]**

## The sidebar, Home and the pull request band

Written for the web, whose list and sidebar Freek called "very very empty". **None of this was
seen**, as with the rest of this document: it is read from the code, and where it says how
something looks, that is what the code draws rather than what anybody photographed.

**Where the decisions live**, all pure and tested in the core unless marked otherwise: **[checked]**

| Decision | Where |
| --- | --- |
| A local workspace's one-word state, in precedence order | `WorkspaceStatus.resolve` and `WorkspaceStatus.ofBranch`, `Sources/BloomCore/Model/WorkspaceStatus.swift` |
| **A Cloud workspace's state, from runbloom.app's list item alone** | `CloudWorkspaceStatus` and `CloudSidebarMark.name(for:activity:)`, `Packages/BloomClient/Sources/BloomClient/Presentation/CloudWorkspaceStatus.swift` |
| Which states get a mark in the sidebar | `SidebarMarkPolicy.drawsMark`, `Sources/BloomCore/Presentation/SidebarMarkPolicy.swift` |
| The sidebar's two groupings, and the status sections | `SidebarGrouping`, `SidebarStatusGroup.of(_:unread:)`, `SidebarStatusListing.build` |
| Home's filter, order, date headings and counts | `HomeList.build`, `HomeList.bucket(for:now:calendar:)`, `HomeList.summary`, `HomeScope`, `HomeOrder`, `HomeAge.short` |
| Home's empty screens | `HomeEmptyState.resolve` |
| The pull request band's headline, tone, detail and button | `PullRequest.status(local:)` and `PullRequestStatus`, `Sources/BloomCore/GitHub/PullRequestStatus.swift`; the checks sentence is `GitHub.rollup` |

The glyph and colour for each state are the one thing that is a view: `symbol(for:)` and
`tint(for:)` in `Sources/Bloom/Views/Sidebar/WorkspaceStatusGlyph.swift`, listed below.

### The states, and the mark each one draws

`WorkspaceStatus`, most urgent first. Two can be true at once (an agent running on a branch whose
checks are red) and the row has room for one, so **the first that is true wins**: **[checked]**

| State | Label | Mark | Colour | Mark in the sidebar |
| --- | --- | --- | --- | --- |
| `settingUp` | Setting up | small spinner | | yes |
| `awaitingPermission` | Waiting on you | `questionmark.circle.fill` | waiting | yes |
| `running` | Agent running | **the pulsing dot** | running (blue) | yes |
| `setupFailed` | Setup failed | `exclamationmark.triangle.fill` | warning | yes |
| `unread` | Unread | `circle.fill`, a size smaller | accent | yes |
| `merged` | Merged | `arrow.triangle.merge` | merged (violet) | no |
| `closed` | Pull request closed | `slash.circle` | tertiary | no |
| `conflicted` | Merge conflicts | `exclamationmark.octagon.fill` | negative | yes |
| `checksFailing` | Checks failing | `xmark.circle.fill` | negative | yes |
| `checksRunning` | Checks running | `clock` | warning | no |
| `checksPassed` | Checks passed | `checkmark.circle.fill` | positive | no |
| `draft` | Draft pull request | `pencil` | tertiary | no |
| `pullRequestOpen` | Pull request open | `arrow.triangle.pull` | accent | no |
| `changed` | Has changes | `arrow.triangle.branch` | secondary | no |
| `clean` | No changes | `circle.dotted` | tertiary | no |

Two rules in the precedence are worth porting exactly:

- **Waiting on you outranks running**, because it is the only state that gets worse the longer it
  is left.
- **Unread ranks below every pull request state.** A turn that merged its own pull request ends
  unread, and the row must say "merged", not show a dot. The name still goes to medium weight
  when a workspace is unread, so unread is never lost from the row.

**The sidebar draws a mark only when something is happening or something is wanted**
(`SidebarMarkPolicy`, the last column above). A resting row keeps an empty box of the same size so
the names line up. **Home draws the mark for every state.**

**A Cloud workspace uses the same states**, mapped from runbloom.app's list item by
`CloudSidebarMark` so one column says one thing:

- `setting_up`, `stopping` and `archiving` map to settingUp.
- `setup_failed`, `error` and `blocked` (held by a team limit) map to setupFailed.
- `waiting_for_input` maps to awaitingPermission, and `running` to running.
- Idle or asleep falls to the branch: a pull request that is merged maps to merged, closed to
  closed, any other state to pullRequestOpen. With no pull request it is unread if the item is
  unread, then changed if the diff has files, else clean.

**While a Cloud workspace is open, its machine's own stream overrides the poll** for running,
waiting and setting up, because the poll said "running" for a turn that had already ended.
**[checked]**

### The sidebar row

`Sources/Bloom/Views/Sidebar/WorkspaceRow.swift`, and `Sources/Bloom/Views/Cloud/CloudWorkspaceRow.swift`
for a Cloud one, which is built from the same pieces. Left to right: **[checked]**

1. **The mark**, in the icon column, by the rules above.
2. **The name**, one line, truncated at the tail. **Medium weight when a turn finished and nobody
   has read it.**
3. **A colour dot**, if this person gave the workspace a colour. For Cloud workspaces the mark is
   personal on runbloom.app and uses the same ten-colour palette. **[checked]**
4. *(space)*
5. **A pin**, if pinned. Local only.
6. **A red `× 2`**: how many of this turn's subagents failed. Only when there are failures.
7. **The subagent chip, the `>3` in the screenshot**: a chevron and the number of subagents the
   running turn has, in accent on a 12% accent capsule. It is a button that shows or hides their
   rows under the workspace, and the chevron turns down while they are shown. It appears only while
   a turn has subagents. It counts subagents, not crew. **Crew agents** (other agents started in
   the same worktree, which outlive the turn) are rows of their own, indented under the
   workspace, each with a dot and a name.
8. **The diff stat, `+405 −4`, in quiet ink**, not green and red, because on a dozen rows the
   colour made it the loudest thing in the pane. Shown only when there is a diff. Full colour is
   kept for the hover card, Home and the inspector.
9. **The project's tile**, only in the status grouping, where rows from different projects are
   mixed.
10. **Under the pointer**, items 6 to 9 fade out and an **archive button** takes their place.

A Cloud row has **no pin or subagent chip**. It adds **a two-person mark** when it is shared with
the team or with the reader. Because the Cloud section mixes projects, its trailing project tile
uses the same `RepoIcon` renderer as a local status row. Initials occupy the tile immediately and
authorised `project.icon_url` artwork replaces them in place after an authenticated API read. A
missing, malformed, broken or superseded URL leaves the initials in place. The personal workspace
colour remains a separate dot beside the workspace name. Its right-click menu offers that colour,
the stored project icon status, and the exact authorised refresh action when runbloom.app supplies
one. Reading or refreshing project icon state never wakes a workspace machine. The current
`project.settings_url` remains a bearer-authenticated API endpoint. When runbloom.app separately
supplies `project.browser_settings_url`, the menu offers Project Settings and opens that exact URL
in the default browser, where normal browser sign in applies. The Mac neither invents the page nor
adds credentials. Its diff is `summary.diff`, shown when `files > 0`.

**Hovering a row opens a card** (`WorkspaceHoverCardView`, decisions in `WorkspaceHoverCard`) with
the branch, the diff in full colour, the pull request, its checks and the age. The row has no
tooltip because the card replaces it.

### The project row

`Sources/Bloom/Views/Sidebar/RepoHeaderRow.swift`. Left to right: **[checked]**

- **A chevron** that folds the project's workspaces away.
- **The project's tile**, which becomes a **settings gear** under the pointer. The two are stacked
  in the same box, so nothing moves.
- **The name**, in the heading style, **one step bolder while any workspace in it is unread**.
  That matters most when the project is folded, because the header is then the only thing left
  saying so.
- *(space)*
- **A `+`** for a new workspace in this project. It is drawn quieter than the name and lights
  under the pointer.
- A right-click menu (new workspace, rename, settings, remove), and drag to reorder.
- **A hidden project is drawn at reduced opacity. Its workspace rows are not dimmed**, because they
  are real work.

### How the sidebar is arranged

Two groupings, chosen in the filter menu at the foot of the pane (`SidebarGrouping`). **Status is
the default.** **[checked]**

- **Status**: sections headed in small capitals with a count: **Needs you** (waiting on you, setup
  failed), **Ready to read** (unread, **including an unread workspace whose mark shows a pull
  request state**), **Working** (running, setting up), **Idle** (everything else). Empty sections
  are not drawn. Idle is ordered most recently touched first, and can be folded once it has 4
  rows. The other sections keep project order.
- **Project**: each project's header with its workspaces under it, in an order the owner drags.
- **Bloom Cloud workspaces** are a section of their own under the heading "Bloom Cloud
  workspaces".
- **The foot of the pane** holds Home, New and Ask Bloom as buttons, then the filter and the
  legend (every state's mark and name, drawn from `WorkspaceStatus.allCases`).

### Home

`Sources/Bloom/Views/Home/HomeView.swift`, the centre pane when nothing is selected. **Every local
workspace on this Mac, newest first, as one flat list under date headings.** It is not grouped by
project, because the sidebar already does that. Top to bottom: **[checked]**

1. **A strip**: a segmented control with **All** and **Archived**, each with its count, then a
   project menu. Searching (Cmd+K) turns the chips into **Everything**, **Workspaces** and
   **Transcripts**, and adds a removable chip holding the query. Under Archived only, a
   **Recent / Largest** order control appears. Three other chips (Needs you, Running, Live) were
   removed at Freek's request; the code says Needs you is the one to bring back if it is missed.
2. **Date headings**, in the title style, **with no count on them**:
   - Today, Yesterday, then "3 days ago" and so on up to a week.
   - Last week, "2 weeks ago", "3 weeks ago".
   - Earlier this month, then month names, with the year added for another year.

   Searching or ordering by size removes the headings.
3. **The rows**, two lines each (`HomeListRow`):
   - **Leading**: the project's tile. Home is flat, so the project is what cannot be told from
     anywhere else on the row.
   - **Line one**: the name (medium weight if unread), then a pin if pinned.
   - **Line two: the project's name, a slash and the branch.** This line was added because Freek
     found the one-line rows "thin with a lot of air".
   - **Trailing, three fixed-width columns so they line up down the list**:
     - **The status mark**, for every state. An archive box instead for an archived workspace.
     - **The diff stat in full colour**, 84 points wide. For an archived workspace this column
       shows its size in bytes.
     - **The age**, 34 points wide: "now", "5m", "3h", "2d", "3w", "4mo", "1y" (`HomeAge.short`).
   - An archived row is greyed as a whole.
   - There is no hover button. The right-click menu is the sidebar's.
4. **A status bar at the foot** with one sentence about the whole list (`HomeList.summary`), for
   example "42 workspaces in 3 projects · 30 live, 12 archived", or under Archived the bytes held
   and the database size.
5. **When the list is empty**, a centred message naming which of five empty states it is, with the
   button that fixes it (`HomeEmptyState`).

**Home lists local workspaces only on this branch**: `HomeView` does not read the Cloud list.
**[checked]** So the Mac has no Cloud equivalent of Home to copy. The nearest thing is the
sidebar's Cloud section with the rows described above.

### The pull request band

`Sources/Bloom/Views/Inspector/PullRequestBar.swift` and `PullRequestSummary.swift`. It is a strip
one row tall across the top of the inspector column, the same for a local workspace and a Cloud
one: a Cloud workspace's pull request is mapped into the same type (`CloudPullRequestMapping`).
**[checked]**

- **The whole strip is washed in the state's tone**: neutral (no wash), positive, negative,
  warning or merged. It is a wash across the full width, not just a coloured word, so the state is
  visible from across the room.
- **Left: the badge**, "#498" in the tone's colour, linking to GitHub, and a "Draft" chip when it
  is a draft.
- **Middle: the headline, which is the state rather than the title**, in the tone's colour. Under
  it, **a detail line** in caption size (the "1 check running" in the screenshot).
- **Right: one button, chosen by the state** (`PullRequestStatus.remedy`): **Merge** (a split
  button with the merge method), **Mark ready for review**, **Fix merge conflicts**, or **Push** /
  **Commit and push**. Continue and Archive appear once it has merged. The button is replaced by
  a spinner while an action is under way, and is disabled while the workspace's agent is mid turn
  (`BranchActionAvailability`).
- **With no pull request**, the strip offers to create one instead.
- A right-click menu: Open on GitHub, Copy link, Share.

The headline and tone, worst first (`PullRequest.status`):

| Case | Headline | Tone | Button |
| --- | --- | --- | --- |
| merged | Merged | merged | (none) |
| closed | Closed | neutral | (none) |
| conflicts | Merge conflicts, "This branch conflicts with the base branch" | negative | Fix merge conflicts |
| draft | Draft, with the checks sentence | neutral | Mark ready for review |
| open, a required check failed | Checks failing | negative | Merge |
| open, checks running or queued | Checks running / Checks queued | warning | Merge |
| open, checks unreadable | GitHub's "checks unavailable" sentence | warning | Merge |
| open, changes requested | Changes requested | warning | Merge |
| open, review required | Waiting for review | warning | Merge |
| open, otherwise | Ready to merge | positive | Merge |

**Local work outranks a cheerful answer.** If the worktree has work GitHub does not (open, no
conflicts), the button becomes Push or Commit and push. A positive headline also becomes **"Local
changes"** in warning, with a detail such as "2 files to commit, 1 commit to push", because "Ready
to merge" over unpushed work is the wrong answer rather than a slightly stale one. A Cloud
workspace passes no local work (its strip is given `localWork: nil`), so this rule does not
apply to it on the Mac.

The detail line is the checks sentence from `GitHub.rollup`, in this order:

1. "1 required check failed"
2. "N checks running"
3. "N checks queued"
4. "N optional checks failed" (still positive)
5. "N checks passed"

## Deleting a Bloom Cloud workspace, as the Mac asks it

Worth porting, because every client calls the archive route and the result cannot be undone. The
Mac presents that action as Delete Workspace and raises `CloudArchivePopover` from whatever
control was clicked: the sidebar row's delete button, the pull request strip's Delete Workspace
button, or, for a caller with nothing on screen to point at, the window.

What it says, in this order, is `CloudArchiveConfirmation`:

1. The workspace's name, on its own line under a fixed title. A name is not a word and never goes
   inside the question.
2. The permanent-loss sentence, always first: the machine, worktree, conversation and any
   unpushed work are deleted with no restore path.
3. Whatever else would be lost, from the machine's `archive_preview` when it answers, and from
   runbloom.app's last summary when it does not.
4. One quiet line beside the consequences saying whether the machine has been asked yet. A machine
   that never answered says so rather than blocking. **Deletion never waits on the machine**,
   because the workspace somebody most wants out of is the one whose machine will not wake, and
   the archive route is the control server's work.
5. What survives: the branch on GitHub, with everything pushed to it.

The anchored popover fits its content rather than reserving space for a worst-case answer. Every
consequence and the survival sentence wraps in full, including at the probe's narrow width. The
Mac's offscreen probe renders light and dark appearances, Increased Contrast and Reduce
Transparency, checks the complete accessibility reading order, and verifies that Escape cancels
while Return does nothing.

## What the wire would need, in the order it decides

Anything here is the Runner's before it is the web's.

1. **A project's quick prompts**, so the panel is not half empty on a Cloud workspace. The only
   composer feature that is genuinely absent rather than unported.
2. **The model catalogue**, or an agreement that each client carries its own. The chosen values
   round-trip today; the menus do not.
3. **Codex's speed reading**, if it is worth a field at all.
4. **Reopening a closed chat.**

**Not on this list, and worth saying so nobody goes to the Runner for it: several terminals.** The
machine already keeps several named sessions and records who opened each, so naming, several and a
layout are a client feature rather than a protocol one.

Everything else in this document either works on Cloud today or needs no protocol change.

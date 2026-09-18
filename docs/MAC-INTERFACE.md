# What the Mac's interface offers, for the web to port

Written for the web client, which has been building against a composer nobody had written down.
Every control the Mac's conversation surface has, what it does, where its state lives, whether a
Cloud workspace has it at all, and what the wire would need for the web to have it.

**How to read the confidence marks.** Every entry is one of two things:

- **[checked]** read in the code while writing this, with the file named.
- **[unsure]** believed but not verified here. Check before building on it.

Nothing in this document is recalled without a mark. A confident wrong entry costs the web more
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
- **Survives a launch**: locally yes, on the session row. **[unsure]**. I did not read the write
  path; `ComposerView.apply(controls:)` is where to look.
- **Cloud**: yes, and it is already on the wire. `ComposerControlsRecord` carries `agent`, `model`,
  `effort`, `permissionMode`, `interactionMode`, `fastMode`, `codexFastMode`, `outputStyle`,
  `codexContextWindow`. The Mac reads it through `CloudChatLink.controls` and writes it back with
  the `set_composer` operation. A chat that does not exist yet takes `composer_defaults` off the
  workspace snapshot. **[checked]**
- **Wire needed**: none. This is the one control that is completely portable today.
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
- **Cloud**: it reads the same `TranscriptRow`s, which a Cloud chat has, so it should work.
  **[unsure]**. I have not confirmed that a machine's `message` rows carry the payload
  `ContextWindowUsage` parses.
- **Wire needed**: probably none. Verify against a live machine before relying on it.
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
- **Shortcut**: none, but `/btw` in the box does the same. **[unsure]** on the slash command.

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
- **Shortcut**: none on the button. **[unsure]** whether anything in the menu bar stops a turn.

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
  Cloud side. The machine's own tmux may keep the shell alive; the *pane* does not remember
  anything. **[unsure]** on what the machine does with the session after the socket drops.

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
- **Recently closed chats**, offered back from the `+` menu. **Local only today**: the three verbs
  are on `WorkspaceSurface` with defaults that answer an empty list, so a Cloud workspace gets no
  section at all rather than a greyed one. **[checked]** A machine learning to reopen a chat is one
  implementation rather than a second menu.

## What the wire would need, in the order it decides

Anything here is the Runner's before it is the web's.

1. **A project's quick prompts**, so the panel is not half empty on a Cloud workspace. The only
   composer feature that is genuinely absent rather than unported.
2. **The model catalogue**, or an agreement that each client carries its own. The chosen values
   round-trip today; the menus do not.
3. **Codex's speed reading**, if it is worth a field at all.
4. **Terminals as a plural**: naming, several, and a layout, if the Cloud app is ever to have what
   the Mac has around a shell.
5. **Reopening a closed chat.**

Everything else in this document either works on Cloud today or needs no protocol change.

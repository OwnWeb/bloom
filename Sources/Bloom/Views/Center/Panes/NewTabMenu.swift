import SwiftUI
import BloomCore

/// What the `+` in the title bar offers: a new tab of any kind in the workspace on screen.
///
/// It was the last thing in the tab strip, and it is the reason the strip could not disappear
/// while a workspace had one tab. It moved to the title bar, beside search and the inspector, so
/// the strip can go the way Safari's does (see `TabStripVisibility`) and the `+` is still in the
/// same place whether it is there or not. Safari keeps its own `+` in the toolbar for the same
/// reason.
///
/// One control for all four kinds, because they differ in what they open and in nothing else.
///
/// The shortcuts are drawn here and fired from the File menu. A `Menu` in a view becomes an
/// `NSMenu` hanging off a button, and key equivalents are only offered to the menu bar and to the
/// view hierarchy, neither of which that menu is in, so what is written here is a label. This used
/// to be backed by an invisible `ZStack` of buttons that registered the same keys in the view
/// hierarchy; the menu bar carries them now, and it has to be one or the other. A view hierarchy
/// button and a menu item bound to the same key are not a tie: the button wins and the item never
/// fires, measured.
///
/// The first three take their name and their glyph from `PaneKind` rather than spelling them out,
/// because the pane's split submenus offer the same three and the two lists have to keep saying
/// the same words.
struct NewTabMenu: View {
    let model: WorkspaceModel

    private var store: WorkspaceTabsStore { .shared }

    private var tabs: CenterTabStore { .shared }

    private var launcher: RunScriptLauncher { .shared }

    var body: some View {
        Menu {
            Button(PaneKind.chat.title, systemImage: PaneKind.chat.symbol, action: newChat)
                .keyboardShortcut("t", modifiers: .command)
            Button(PaneKind.terminal.title, systemImage: PaneKind.terminal.symbol, action: newTerminal)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(PaneKind.browser.title, systemImage: PaneKind.browser.symbol, action: newBrowser)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            // **Never disabled, and it used to be**, on the argument that an empty review has
            // nothing to show. It has: the pane says what the worktree is being compared against
            // and that nothing differs from it yet, which is an answer, and it is the answer
            // somebody who picked this row was asking for. Greyed out it read as a broken menu
            // item, which is how it was reported. The File menu's own Show Changes has been
            // enabled on any workspace all along, and the two saying different things about the
            // same tab was the other half of the confusion.
            Button(PaneNaming.changes, systemImage: PaneGlyph.review) { model.openReview() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            // An empty note is exactly what somebody opening this is about to fix.
            Button(CenterTab.notesTitle, systemImage: PaneGlyph.notes) { model.openNotes() }
            runScriptItems
            reopenItems
        } label: {
            Label("New Tab", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        // Re-read on the way to the button, because a `Menu` has no moment of its own to do it
        // in: its items are built before it opens. A run script added from a terminal inside
        // Bloom changes no selection and brings no window forward, so without this it only reached
        // the menu on the next switch. The read is coalesced and off the main actor, and the
        // pointer takes longer to reach the button than the parse takes.
        //
        // The closed chats ride the same moment for the same reason, and they are also refreshed
        // on every close, so the list is right even on a menu that is opened from the keyboard
        // and never hovered.
        .onHover {
            guard $0 else { return }
            model.refreshSettings()
            Task { await model.refreshClosedChats() }
        }
        // The first opening of this menu in a launch has had no close and no hover behind it, and
        // an empty Recently Closed section is indistinguishable from a chat that cannot come back.
        .task(id: model.workspace.id) { await model.refreshClosedChats() }
        .accessibilityLabel("New Tab")
        .help("New tab in this workspace")
    }

    /// The project's run scripts, under their own heading, in the order the file states them.
    ///
    /// Absent rather than an empty heading for a project with none, so the menu is exactly what it
    /// was before run scripts had tabs. Each row's second line is the command, so what runs can be
    /// read before it runs, and a script already going says Running instead, because picking it
    /// shows its tab rather than starting a second copy. The words are `RunScriptMenuItem`.
    @ViewBuilder
    private var runScriptItems: some View {
        let scripts = model.runScripts
        if !scripts.isEmpty {
            let running = runningScripts()
            Divider()
            Section("Run Scripts") {
                ForEach(scripts) { script in
                    let item = RunScriptMenuItem.make(
                        script: script,
                        isRunning: running.contains(script.id),
                        missingFile: missingFile(of: script)
                    )
                    Button {
                        model.pickRunScript(script)
                    } label: {
                        // A label and then a second text, which a menu draws as the title with
                        // its glyph and a subtitle under it.
                        Label {
                            Text(verbatim: item.title)
                        } icon: {
                            Image(systemName: RunScriptGlyph.symbol(for: script.icon))
                        }
                        Text(verbatim: item.subtitle)
                    }
                    .disabled(!item.isEnabled)
                }
            }
        }
    }

    /// The chats this workspace has closed, newest first, each offering to come back.
    ///
    /// **Here rather than in a window of its own, because this is where a chat is made and this is
    /// where one comes back**, which is the arrangement Safari has and the one a reader already
    /// knows. The alternative considered was the archive's shape, a sheet listing closed chats the
    /// way Home lists archived workspaces; that is the right screen for deciding what to delete
    /// and the wrong one for undoing a mis-click, which is a thing somebody wants two seconds
    /// after doing it and without leaving the pane.
    ///
    /// Absent rather than an empty heading when there is nothing to offer, which is how
    /// `runScriptItems` above treats a project with no scripts.
    ///
    /// Each row carries its agent, its size and its age as a subtitle, because "Chat 3" alone
    /// cannot be told from the other "Chat 3". The words are `SessionReopening`.
    @ViewBuilder
    private var reopenItems: some View {
        let chats = model.closedChats
        if !chats.isEmpty {
            Divider()
            Section(SessionReopening.sectionTitle) {
                // The clock is read here rather than when the list was loaded: the load happens on
                // the way to the button and the menu can stand open afterwards, so an age stamped
                // at load time would be the age at a moment the reader never saw.
                let now = Date()
                ForEach(chats) { chat in
                    Button {
                        Task { await model.reopen(chat) }
                    } label: {
                        // A label and then a second text, which a menu draws as the title with its
                        // glyph and a subtitle under it. The same shape as a run script row.
                        Label {
                            Text(verbatim: SessionReopening.title(chat))
                        } icon: {
                            Image(systemName: PaneKind.chat.symbol)
                        }
                        Text(verbatim: SessionReopening.subtitle(chat, now: now))
                    }
                }
            }
        }
    }

    /// The ids of the run scripts with a tab whose command is going.
    private func runningScripts() -> Set<String> {
        Set(tabs.tabs(for: model.workspace.id).compactMap { tab in
            launcher.isRunning(tab) ? tab.runScriptID : nil
        })
    }

    private func missingFile(of script: RunScript) -> String? {
        guard let file = model.missingRunScriptFile(script) else { return nil }
        return file
    }

    /// All three go through `NewPane`, which is the same door the pane's split submenus use, so a
    /// tab made from the `+` and a tab made by splitting are the same tab.
    ///
    /// A new tab, selected, rather than a new pane in the focused one. That is what the strip's `+`
    /// did too: the strip is one row for the workspace rather than one per pane, so there never was
    /// a per-pane `+` whose meaning moving it could lose. Opening beside the focused pane is the
    /// View menu's Split Right and Split Down.
    private func newChat() {
        NewPane.open(.chat, in: model) { store.select($0, in: model) }
    }

    private func newTerminal() {
        NewPane.open(.terminal, in: model) { store.select($0, in: model) }
    }

    /// The `+` opens a browser on the workspace's own dev server, where a split opens one on
    /// nothing. That is not drift: this item is the one that means "look at what this workspace is
    /// running", and it is the only route that knows where that is.
    private func newBrowser() {
        let model = model
        Task {
            let address = await model.browserAddress()
            NewPane.open(.browser, in: model, url: address) { store.select($0, in: model) }
        }
    }
}

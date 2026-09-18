import AppKit
import BloomClient
import Foundation
import SwiftUI
import BloomCore
import BloomProtocol

/// A Cloud workspace's conversations, as the window asks for them: the machine's chats drawn as
/// the app's own `Session`, what is in front, and what the composer needs to know before anybody
/// types. See `WorkspaceSurface`.
extension CloudWorkspaceSession {
    // MARK: Its conversations

    /// The machine's chats, in the order it keeps them, as the app's own `Session`. Crew members an
    /// agent started are left out the same way a local workspace leaves them out of its strip:
    /// `topLevelChats` is the machine's own answer to that question.
    var chats: [Session] {
        state.topLevelChats.map(Session.init(cloudChat:))
    }

    /// The workspace snapshot carries every chat, so there is no moment where the list is empty
    /// because nobody has asked: either this workspace has been read or it has not.
    var hasReadChats: Bool { state.workspace != nil }

    var activeChat: Session? {
        guard let id = selectedChatID else { return nil }
        return chats.first { $0.id == id }
    }

    /// Selecting a tab adopts the chat in it, which for a Cloud workspace is the tab strip's own
    /// selection: there is no second place that remembers which conversation is in front.
    var activeChatID: SessionID? {
        get { selectedChatID }
        set {
            guard let newValue else { return }
            WorkspaceTabsStore.shared.select(.chat(newValue), in: self)
        }
    }

    /// Opening the connection is what wakes a sleeping machine, so it happens when the column
    /// arrives on the workspace and not before.
    func onColumnAppear() async {
        open()
        await cloud.markRead(id)
    }

    /// The machine has run scripts and they are not tabs here yet, so there is nothing for the
    /// column to offer or to start.
    var runScripts: [RunScript] { [] }
    func considerRunScriptAutostart() {}
    func refreshSettings() {}

    func pickRunScript(_ script: RunScript) {}
    func missingRunScriptFile(_ script: RunScript) -> String? { nil }

    func openReview() { open(.review) }

    /// Notes are not on the wire yet.
    var supportsNotes: Bool { false }
    func openNotes() {}

    /// The only tab a Cloud workspace has that a local one does not: what its machine did while it
    /// was starting, which is the only account of a machine's first few minutes.
    var supportsSetupTab: Bool { true }
    func openSetupLog() { open(.setup) }

    /// Nothing: a Cloud workspace's settings file is on its machine, and what it says about setup
    /// is the setup banner and the Setup tab rather than a strip over the panes.
    func settingsNotices() -> EmptyView { EmptyView() }

    /// A new Cloud workspace's first minutes, which is the only time it has more to say than the
    /// pane does: its machine is setting itself up, and the first message typed at create is
    /// waiting for it. Said with the message itself, because it is the one thing the reader did.
    var emptyPaneNotice: PaneEmptyNotice? {
        if isRunningSetup {
            return PaneEmptyNotice(
                glyph: PaneGlyph.setup,
                title: "Setting up this Cloud workspace",
                message: heldPrompt.map { "Your first message goes as soon as it is ready: “\($0.text)”" }
                    ?? "It is cloning the repository and running the project's setup. This takes a few minutes the first time.",
                actionTitle: "Watch Setup",
                action: { [weak self] in self?.openSetupLog() }
            )
        }
        if let held = heldPrompt {
            return PaneEmptyNotice(
                glyph: "clock",
                title: "Your first message is waiting",
                message: "“\(held.text)” goes to the agent as soon as this Cloud workspace has started."
            )
        }
        return nil
    }

    func isRunningChat(_ id: SessionID) -> Bool {
        state.chats[id.rawValue]?.isRunning == true
    }

    /// Made on first use, with its history read. See `CloudWorkspaceSession.transcript(for:)`.
    func prepareTranscript(for id: SessionID) {
        _ = transcript(for: id)
    }

    /// Asks the machine for a chat, and answers the tab to put in front once it has one.
    func createChat(title: String?) async -> PaneContent? {
        await newChat()
        return selectedChatID.map(PaneContent.chat)
    }

    /// Closing a Cloud chat is the machine's `close_chat`, which is what `close(_:)` sends. There
    /// is nothing to ask about first: the conversation is the machine's and closing it does not
    /// throw away a worktree.
    func closeChat(_ session: Session) {
        close(.chat(session.id))
    }

    func renameChat(_ session: Session, to title: String) {
        rename(.chat(session.id), to: title)
    }

    /// Nowhere to write it: the machine keeps the order of its own chats, and the interleaving of
    /// chats and tools in the strip is written by `WorkspaceTabsStore` for both kinds.
    func reorderChats(to order: [SessionID]) {}

    /// The machine has run scripts, and they are not a tab kind here yet.
    func runScript(id: String) -> RunScript? { nil }

    /// A Cloud workspace's own app is its preview, which opens through the preview token rather
    /// than by typing an address, so a browser tab is not one of the kinds its `+` offers.
    func browserAddress() async -> String { "" }
    var supportsBrowserTabs: Bool { false }

    // MARK: A conversation in it

    /// The machine's setup, which is what a new Cloud workspace spends its first minutes doing.
    var isRunningSetup: Bool {
        ["pending", "running"].contains(state.setup?.state ?? "")
    }

    /// Kept on the session, so where somebody had got to in a conversation survives switching tab
    /// and switching workspace, exactly as it does for a local one.
    func transcriptMemory(pane: String) -> TranscriptPaneMemory {
        TranscriptPaneMemory(
            pane: pane,
            read: { [weak self] session in self?.panePositions[TranscriptPaneState.Key(pane: pane, session: session)] },
            write: { [weak self] state, session in
                self?.panePositions[TranscriptPaneState.Key(pane: pane, session: session)] = state
            }
        )
    }

    /// The chat a review sends to, when somebody has picked one rather than taking the chat in
    /// front. Kept on the session, because it is about this window's reading rather than the
    /// machine's state.
    var reviewDestinationID: SessionID? {
        get { chosenReviewDestination }
        set { chosenReviewDestination = newValue }
    }

    /// No worktree on this Mac, so the composer offers what it offers Ask Bloom.
    var composerWorkspace: WorkspaceModel? { nil }

    /// What runbloom.app would refuse a turn for, said before anything is typed rather than a
    /// minute later with the same sentence and nothing to press.
    func composerNotice(for transcript: TranscriptModel) -> ChatComposerNotice? {
        guard let teamID = cloud.item(id)?.teamID,
              let readiness = CloudPromptReadiness(
                  account: cloud.account, teamID: teamID, agent: transcript.session.agentKind.wireName
              )
        else { return nil }
        return ChatComposerNotice(
            sentence: readiness.sentence,
            actionTitle: readiness.opensRunbloom ? "Open runbloom.app" : nil,
            action: readiness.opensRunbloom ? { [cloud, id] in NSWorkspace.shared.open(cloud.runbloomPage(forWorkspace: id)) } : nil
        )
    }

    /// Nothing hangs over a Cloud conversation: side conversations are a second agent in the same
    /// worktree, and there is no worktree here to hold one.
    func chatLayer(for transcript: TranscriptModel) -> EmptyView { EmptyView() }
}

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
    /// The staging directory for this chat, laid out as a worktree is. See
    /// `WorkspaceSurface.attachmentRoot`.
    func attachmentRoot(for chat: SessionID) -> String {
        AttachmentStaging.directory(draftID: chat.rawValue)
    }

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

    /// **Nil, and this is load-bearing rather than a gap.** Everything this workspace knows about
    /// which chat is in front, it knows from `WorkspaceTabsStore`, so answering anything else here
    /// would be the store asking itself: see `WorkspaceSurface.preferredChatID` for the crash that
    /// was. The strip opens on its first entry, which is the right answer for a workspace whose
    /// chats have only just arrived from its machine.
    var preferredChatID: SessionID? { nil }

    /// The selected tab and its focused pane already determine the active Cloud chat.
    /// Calling back into tab selection here would recurse when the pane's chat is claimed by
    /// a tab rooted on another chat.
    func adoptActiveChat(_ id: SessionID) {}

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
    var supportsNotes: Bool { true }
    /// The workspace's own note, kept by its machine so that it is the workspace's rather than
    /// this Mac's. See `CloudNotesPane`.
    func openNotes() { open(.notes) }

    /// Nothing: a Cloud workspace's settings file is on its machine, and what it says about setup
    /// is the setup banner and the Setup tab rather than a strip over the panes.
    func settingsNotices() -> EmptyView { EmptyView() }

    /// A new Cloud workspace's first minutes, which is the only time it has more to say than the
    /// pane does: its machine is being made, and the first message typed at create is waiting for
    /// it.
    ///
    /// **One notice, and the words are `CloudOpeningNotice`'s.** There were two here, and the
    /// wrong one of the two won for the whole of the first minute: a machine that had not yet
    /// reported a step fell through to a clock glyph over "Your first message is waiting", so the
    /// screen somebody meets on their first Cloud workspace had the **queue** as its subject while
    /// a machine was being made and a repository cloned. The message is a line underneath now
    /// rather than the headline, because it is worth keeping and it is not what is happening.
    var emptyPaneNotice: PaneEmptyNotice? {
        guard let notice = CloudOpeningNotice.of(
            setup: state.setup, log: state.setupLog, heldPrompt: heldPrompt?.text
        ) else { return nil }
        return PaneEmptyNotice(
            glyph: PaneGlyph.setup,
            title: CloudOpeningNotice.title,
            message: notice.message,
            progress: notice.progress ?? connectionProgress
        )
    }

    /// What the connection is doing, for the moments the machine itself has said nothing.
    ///
    /// **Nothing the banner over the column already states in full**, which is a rule this had
    /// written down three lines from where it was broken: `notReady` returned runbloom.app's own
    /// sentence, which is exactly what the banner is showing, so "its machine is not ready yet,
    /// and this will reconnect automatically once it is" appeared twice on one screen and made it
    /// read as stalling rather than working. A workspace that is asleep, refused, archived or over
    /// a limit is not making progress towards anything, and reconnecting is machinery talking
    /// about itself.
    private var connectionProgress: String? {
        switch phase {
        case .connecting(let waking): waking ? "Waking the machine" : nil
        default: nil
        }
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

    /// A Cloud workspace's own app is its preview, and it opens through a token rather than an
    /// address: the `+` offers the tab, and the pane asks for the address itself every time it
    /// draws. So there is nothing to hand over here, and an empty one is what `NewPane` opens the
    /// tab with. See `CloudPreviewPane`.
    func browserAddress() async -> String { "" }
    var supportsBrowserTabs: Bool { true }

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

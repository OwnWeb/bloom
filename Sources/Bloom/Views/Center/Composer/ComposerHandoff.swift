import SwiftUI
import BloomCore

/// The one route from somewhere else in the window into the composer's next prompt.
///
/// A browser pane and the checks list both have the same problem: they are showing something the
/// agent should see, and they are nowhere near the box you would type it into. Both used to end in
/// the user taking a screenshot by hand or selecting a log and copying it. This is what a button in
/// either of them calls, and it is deliberately the same door the paperclip and a drag already go
/// through, `PromptAttachmentStore.add`, so a file that arrives this way is a file in every respect
/// the composer already knows about: it is copied under `.bloom/attachments`, it is a chip, it is
/// undoable, it is removed if the sentence stops naming it, and it survives a relaunch.
///
/// It is not a view and it does not draw. The button that calls it is the view's whole share.
@MainActor
enum ComposerHandoff {
    /// What came of it: nothing to report, or a sentence to put in front of the user.
    ///
    /// A failure has to be spoken. Something that quietly did not arrive in the composer is
    /// indistinguishable from a button that does nothing, and this is a button whose entire
    /// promise is that the file is now in the prompt.
    struct Outcome: Sendable {
        var failure: String?
        var paths: [String] = []
    }

    /// Attaches to the workspace's active session, writes `body` at the end of that draft, and
    /// brings the conversation into view.
    ///
    /// **At the end of the draft rather than at the caret**, which is the one place this differs
    /// from a drop. A drop knows where it was let go; a button in another pane does not, and the
    /// caret it would find is wherever the user last left it, which is as likely to be the middle
    /// of a word as anywhere. The end is the only position that is the same every time.
    ///
    /// **The conversation is revealed rather than switched to.** `WorkspaceTabsStore.reveal` does
    /// nothing at all when the chat is already a pane of the tab on screen, which is the split the
    /// browser is normally used in, so a snapshot taken beside the composer does not throw the
    /// browser away to show a box that was never hidden. It is only when the pane is filling the
    /// window that the tab changes, and then it has to: an attachment you cannot see did not
    /// visibly happen.
    ///
    /// **Generic over the workspace rather than about a worktree.** It took a `WorkspaceModel`,
    /// which is a worktree on this Mac, so the one pane a Cloud workspace has that needs this, the
    /// window onto its own app, had no way in. Everything here is the same for both kinds: the
    /// store, the chip, the sentence, the reveal. The one thing that differs is where the bytes are
    /// written, and the workspace answers that: see `WorkspaceSurface.attachmentRoot`.
    @discardableResult
    static func attach<Model: WorkspaceSurface>(
        _ sources: [AttachmentSource],
        to model: Model,
        sessionID: SessionID? = nil,
        revealConversation: Bool = true,
        imageComment: BrowserImageComment? = nil,
        body: @escaping @Sendable ([String]) -> String = { $0.map(AttachmentDraft.token(for:)).joined(separator: " ") }
    ) async -> Outcome {
        // A review can stay open while another chat becomes active. An explicit destination
        // must never fall back to that new chat if the original conversation has been closed.
        //
        // **And the chat in front is not always a chat.** A Cloud workspace's notion of the active
        // one is the tab strip's own selection, so pressing a button in the pane beside the
        // conversation asks a workspace whose selected tab is that pane: it answers nil, and the
        // first chat is the right fallback, because a workspace with one conversation is where
        // this is pressed.
        let destination: Session? = if let sessionID {
            model.chats.first { $0.id == sessionID }
        } else {
            model.activeChat ?? model.chats.first
        }
        guard let session = destination else {
            return Outcome(failure: sessionID == nil
                ? "This workspace has no conversation to attach to yet."
                : "The conversation for this feedback has been closed.")
        }
        model.prepareTranscript(for: session.id)
        guard let transcript = model.existingTranscript(for: session.id) else {
            return Outcome(failure: "This workspace's conversation could not be opened.")
        }

        let key = session.id.rawValue
        let store = PromptAttachmentStore.shared
        store.load(sessionID: key)

        let added = await store.add(sources, sessionID: key, workspace: model.attachmentRoot(for: session.id))
        guard !added.paths.isEmpty else {
            return Outcome(failure: added.failures.first ?? "Nothing could be attached.")
        }

        if let imageComment { store.annotate(paths: added.paths, with: imageComment, sessionID: key) }
        append(body(added.paths), to: transcript)
        if revealConversation { WorkspaceTabsStore.shared.reveal(.chat(session.id), in: model) }

        return Outcome(failure: added.failures.first, paths: added.paths)
    }

    /// A sentence with nothing attached to it, put in the same place by the same rules.
    ///
    /// The case a failed check falls into when its log could not be fetched: the name, the
    /// conclusion and the URL are worth handing over on their own, and going through the
    /// attachment path with no files would only produce a failure to report.
    @discardableResult
    static func write<Model: WorkspaceSurface>(_ sentence: String, to model: Model) async -> Outcome {
        guard let session = model.activeChat ?? model.chats.first else {
            return Outcome(failure: "This workspace has no conversation to write to yet.")
        }
        model.prepareTranscript(for: session.id)
        guard let transcript = model.existingTranscript(for: session.id) else {
            return Outcome(failure: "This workspace's conversation could not be opened.")
        }
        append(sentence, to: transcript)
        WorkspaceTabsStore.shared.reveal(.chat(session.id), in: model)
        return Outcome()
    }

    /// Puts a sentence at the end of a draft, on its own line where there is already something
    /// there.
    ///
    /// A newline rather than a space, because everything that arrives this way is a sentence about
    /// a file rather than a word in one the user was writing, and running it onto the end of a
    /// half-typed thought is how the two become unreadable together.
    private static func append(_ addition: String, to transcript: TranscriptModel) {
        guard !addition.isEmpty else { return }
        let draft = transcript.draft
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcript.draft = addition + " "
            return
        }
        let separator = draft.hasSuffix("\n") ? "" : "\n"
        transcript.draft = draft + separator + addition + " "
    }
}

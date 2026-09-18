import BloomClient
import BloomCore
import BloomProtocol
import Foundation

/// What a Cloud chat's `TranscriptModel` asks its machine to do, and nothing else.
///
/// A small object rather than the session itself, so the transcript model holds a chat id and a
/// weak reference, and a closed workspace leaves its transcripts with verbs that do nothing rather
/// than a session kept alive by them.
@MainActor
final class CloudChatLink {
    let chatID: SessionID
    private weak var session: CloudWorkspaceSession?

    init(chatID: SessionID, session: CloudWorkspaceSession) {
        self.chatID = chatID
        self.session = session
    }

    /// The signed in person, whose own messages carry no name.
    var readerID: String? { session?.readerID }

    /// The workspace this chat is in, so its transcript can draw the machine's setup at its head
    /// the way a local transcript draws a worktree's. Nil once the workspace has been closed.
    var workspaceID: CloudWorkspaceID? { session?.id }

    /// Whether the machine is still making itself, which is why a queued message is not moving.
    /// See `CloudQueueCaption.sentence`.
    var isSettingUp: Bool { session?.isRunningSetup == true }

    /// The chat's controls as the machine last said, which carry the fields a `Session` does not.
    var controls: ComposerControls? {
        session?.state.chats[chatID.rawValue]?.controls.flatMap(ComposerControls.cloud)
    }

    /// Whether it went, did not go, or nobody knows. See `CloudSendOutcome`, which is where the
    /// third answer is argued.
    func send(_ text: String, audience: AudienceRecord? = nil) async -> CloudSendOutcome {
        guard let session else { return .failed(Self.closed) }
        return await session.send(text, chatID: chatID, audience: audience)
    }

    /// Everybody this workspace's messages may be addressed to, other than the reader.
    ///
    /// **The machine's list rather than runbloom.app's, and not `presence`.** Presence is who has
    /// the workspace open, and somebody who is away is exactly the person a mention is most useful
    /// for. It carries no addresses, because a share-link guest reads the same snapshot.
    ///
    /// **The reader is taken out**, because `@` is for reaching somebody else: a menu offering to
    /// address yourself is a menu with a row nobody will ever pick. Empty while the machine has not
    /// been told who is on the team, which by the rule in the core means `@` keeps its file meaning
    /// and none of this can be entered. See `MentionAddress` and `MemberRecord`.
    var people: [ComposerAudience.Person] {
        guard let session else { return [] }
        let reader = session.readerID
        return session.state.members
            .filter { $0.userID != reader }
            .map { ComposerAudience.Person(id: CloudUserID($0.userID), handle: $0.handle, name: $0.name) }
    }

    /// What is answering in this chat, for `@claude` beside `@bloom`.
    var runningAgent: AgentKind? { controls?.agentKind }

    /// Puts a file on the machine and answers the path an agent standing in its worktree reads it
    /// from, or the sentence saying why it is not there.
    ///
    /// **A Cloud chat's attachment crosses a network, which a local one does not.** The composer
    /// writes a path into the draft and the agent opens it, and that works on this Mac because the
    /// file was copied into the very worktree the agent stands in. A machine's agent stands
    /// somewhere else, so the bytes go over the connection when the turn does, and the machine
    /// says where it put them. See `TranscriptModel.uploading` and `AttachmentDraft.mapping`.
    ///
    /// The workspace's, rather than this chat's: a file on a machine belongs to the worktree, and
    /// every chat in the workspace is standing in the same one.
    func upload(name: String, data: Data) async -> CloudWorkspaceSession.Upload {
        guard let session else { return .refused(Self.closed) }
        return await session.upload(name: name, data: data)
    }

    /// Where a file attached to this chat waits until the turn takes it, which is the workspace's
    /// answer rather than this link's. See `WorkspaceSurface.attachmentRoot`.
    var attachmentRoot: String { session?.attachmentRoot(for: chatID) ?? "" }

    /// The notes written on this workspace's diffs and not yet sent, which ride with whatever this
    /// chat sends next. The workspace's own, because a note is about the workspace rather than
    /// about one conversation in it. See `CloudChanges.reviewComments`.
    var reviewComments: [ReviewComment] { session?.reviewComments ?? [] }

    func removeReviewComment(id: ReviewCommentID) {
        session?.removeReviewComments(ids: [id])
    }

    /// Taken away after they have gone with a turn.
    func removeReviewComments(ids: [ReviewCommentID]) {
        session?.removeReviewComments(ids: ids)
    }

    /// Opens the file a note was written on, which for a Cloud workspace is the review tab.
    func openFile(path: String) {
        session?.openFile(path: path, focusing: true)
    }

    func stop() async {
        await session?.run(.stop(chatID: chatID.rawValue))
    }

    func answer(requestID: String, decision: PermissionDecision) async -> WorkspaceConnection.CommandFailure? {
        guard let session else { return .noAnswer(Self.closed) }
        return await session.run(.answer(chatID: chatID.rawValue, requestID: requestID, answer: decision.cloudAnswer), reporting: false)
    }

    @discardableResult
    func cancelQueued(_ id: DeliveryID) async -> Bool {
        guard let session else { return false }
        return await session.run(.cancelQueued(chatID: chatID.rawValue, promptID: id.rawValue)) == nil
    }

    func setComposer(_ controls: ComposerControls) async -> String? {
        guard let session else { return Self.closed }
        return await session.run(.setComposer(chatID: chatID.rawValue, controls: controls.cloudRecord), reporting: false)?.message
    }

    /// Whether the machine recorded it.
    func markRead(seq: Int) async -> Bool {
        guard let session, session.phase == .live else { return false }
        return await session.run(.markRead(chatID: chatID.rawValue, seq: seq), reporting: false) == nil
    }

    private static let closed = "This Bloom Cloud workspace is closed. Open it again to carry on."
}

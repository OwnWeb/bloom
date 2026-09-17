import BloomClient
import BloomCore
import BloomProtocol

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

    /// The chat's controls as the machine last said, which carry the fields a `Session` does not.
    var controls: ComposerControls? {
        session?.state.chats[chatID.rawValue]?.controls.flatMap(ComposerControls.cloud)
    }

    /// Nil when it was queued, otherwise the sentence to show.
    func send(_ text: String) async -> String? {
        guard let session else { return Self.closed }
        return await session.send(text, chatID: chatID)
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

    func markRead(seq: Int) async {
        guard let session, session.phase == .live else { return }
        await session.run(.markRead(chatID: chatID.rawValue, seq: seq), reporting: false)
    }

    private static let closed = "This Cloud workspace is closed. Open it again to carry on."
}

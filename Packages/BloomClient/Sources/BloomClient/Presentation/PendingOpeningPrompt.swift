import BloomProtocol
import Foundation

/// The prompt typed when a Cloud workspace was created, held on this Mac until the machine can
/// take it.
///
/// runbloom.app's create takes no prompt, and a new machine spends a couple of minutes setting up
/// before it answers at all, so the Mac keeps the prompt and sends it the first time it connects.
/// **Kept on disk rather than in memory**, because a Mac relaunched during those minutes would
/// otherwise lose what was typed without a word. Sent once: it is removed the moment the machine
/// answers `queued`, and a send whose outcome is unknown is retried under the command id it was
/// first given, which is kept with it, so a relaunch in the middle cannot queue it twice.
public struct PendingOpeningPrompt: Codable, Sendable, Hashable {
    public var workspaceID: String
    public var text: String
    /// What the person chose in the create window, or nil for "whatever the machine would open
    /// with". Nil is the ordinary case: the window shows this Mac's defaults because no machine
    /// exists yet to ask, and only a deliberate change is worth carrying past the machine's own
    /// answer. See `WorkspaceSnapshotRecord.composerDefaults`, which is better than a guess
    /// because it has read the repository's settings file and the agents in the image.
    public var controls: ComposerControlsRecord?
    /// The id the `new_chat` for it is sent with, kept so a retry after a relaunch opens one chat.
    public var chatCommandID: String
    /// The chat that command made, once it answered.
    public var chatID: String?
    /// The id the `send` is sent with, kept for the same reason.
    public var sendCommandID: String
    public var createdAt: Date

    public init(workspaceID: String, text: String, controls: ComposerControlsRecord?, createdAt: Date = Date()) {
        self.workspaceID = workspaceID
        self.text = text
        self.controls = controls
        chatCommandID = UUID().uuidString.lowercased()
        sendCommandID = UUID().uuidString.lowercased()
        self.createdAt = createdAt
    }

    /// The operation to send next: a chat of its own first, then the prompt into it. A new machine
    /// has no chat until somebody opens one, and opening one under a kept command id is what keeps
    /// a retry from opening two.
    /// - Parameter defaults: what to open the chat with when nobody chose. The machine's own
    ///   answer where it gave one, and this Mac's clamped choice otherwise.
    public func nextOperation(defaults: ComposerControlsRecord) -> (operation: WorkspaceOperation, commandID: String) {
        if let chatID { return (.send(chatID: chatID, text: text), sendCommandID) }
        return (.newChat(controls: controls ?? defaults), chatCommandID)
    }

    /// Prompts older than a day are dropped rather than sent: a workspace that took that long to
    /// start failed, and a prompt arriving tomorrow is not what anybody asked for.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > 24 * 60 * 60
    }
}

/// Every held prompt, as one value to keep in the app's defaults.
public struct PendingOpeningPrompts: Codable, Sendable, Hashable {
    public var prompts: [String: PendingOpeningPrompt]

    public init(prompts: [String: PendingOpeningPrompt] = [:]) {
        self.prompts = prompts
    }

    public static func decode(_ data: Data?, now: Date) -> PendingOpeningPrompts {
        guard let data, let decoded = try? JSONDecoder().decode(PendingOpeningPrompts.self, from: data) else { return PendingOpeningPrompts() }
        return PendingOpeningPrompts(prompts: decoded.prompts.filter { !$0.value.isStale(at: now) })
    }

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

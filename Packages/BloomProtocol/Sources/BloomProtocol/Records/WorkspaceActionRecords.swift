import Foundation

/// What archiving would lose, and the id that confirms it.
///
/// Archiving a Cloud workspace deletes its machine, and with it the conversation, so the preview
/// always says so (`deletes_conversation`), and an archive only goes ahead with a confirmation id
/// whose answer still matches what the machine measures at that moment.
public struct ArchivePreviewRecord: Codable, Sendable, Hashable {
    public var confirmationID: String
    public var hasUncommittedChanges: Bool
    public var untrackedFiles: [String]
    public var unpushedCommits: Int
    public var detachedCommits: Int
    public var isAgentRunning: Bool
    public var isPullRequestMerged: Bool
    public var deletesConversation: Bool
    public var createdAt: Date

    public init(
        confirmationID: String, hasUncommittedChanges: Bool, untrackedFiles: [String], unpushedCommits: Int, detachedCommits: Int,
        isAgentRunning: Bool, isPullRequestMerged: Bool, deletesConversation: Bool = true, createdAt: Date
    ) {
        self.confirmationID = confirmationID
        self.hasUncommittedChanges = hasUncommittedChanges
        self.untrackedFiles = untrackedFiles
        self.unpushedCommits = unpushedCommits
        self.detachedCommits = detachedCommits
        self.isAgentRunning = isAgentRunning
        self.isPullRequestMerged = isPullRequestMerged
        self.deletesConversation = deletesConversation
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case confirmationID = "confirmation_id"
        case hasUncommittedChanges = "has_uncommitted_changes"
        case untrackedFiles = "untracked_files"
        case unpushedCommits = "unpushed_commits"
        case detachedCommits = "detached_commits"
        case isAgentRunning = "is_agent_running"
        case isPullRequestMerged = "is_pull_request_merged"
        case deletesConversation = "deletes_conversation"
        case createdAt = "created_at"
    }
}

/// A run script from the project's settings.
public struct RunScriptRecord: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var command: String

    public init(id: String, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

/// A terminal the server opened, which a client attaches to over the terminal WebSocket by name.
public struct TerminalRecord: Codable, Sendable, Hashable {
    public var name: String
    public var title: String

    public init(name: String, title: String) {
        self.name = name
        self.title = title
    }
}

/// Somebody with an event stream open on this workspace.
///
/// `last_input_at` is the last human input from them (a prompt, an answer, a keystroke, a save),
/// which is what the presence lease counts from; an open stream alone is not input.
public struct PresenceRecord: Codable, Sendable, Hashable {
    public var userID: String
    public var name: String
    public var lastInputAt: Date?

    public init(userID: String, name: String, lastInputAt: Date?) {
        self.userID = userID
        self.name = name
        self.lastInputAt = lastInputAt
    }

    enum CodingKeys: String, CodingKey {
        case name
        case userID = "user_id"
        case lastInputAt = "last_input_at"
    }
}

/// The whole workspace at once: what a client reads when it opens it.
public struct WorkspaceSnapshotRecord: Codable, Sendable, Hashable {
    public var workspace: WorkspaceRecord
    public var chats: [ChatRecord]
    public var presence: [PresenceRecord]
    /// The newest transcript cursor at the time of reading, so a client can open the event stream
    /// from exactly here without missing or repeating a row.
    public var cursor: Int64

    public init(workspace: WorkspaceRecord, chats: [ChatRecord], presence: [PresenceRecord], cursor: Int64) {
        self.workspace = workspace
        self.chats = chats
        self.presence = presence
        self.cursor = cursor
    }
}

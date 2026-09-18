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
    /// **What a chat that does not exist yet would start with**, as the machine would answer it.
    ///
    /// Without this the first chat in a workspace is always started from a guess: `new_chat`
    /// requires `controls`, and `composer` can only be asked about a chat that already has an id.
    /// Two clients guessed differently, which is how a protocol drifts. It is here rather than
    /// behind a call of its own because it arrives with everything else a client already reads and
    /// costs no round trip; the choices to go with it (models, commands, output styles) stay on
    /// `composer`, because discovering those costs a subprocess and a walk of the filesystem and
    /// this record is read on every connect.
    public var composerDefaults: ComposerControlsRecord
    /// Everybody who may be addressed with `@`, which is **not the same list as `presence`**: that
    /// is who is here, and this is who has access. Somebody who is away is exactly the person a
    /// mention is most useful for.
    ///
    /// Each carries a `handle`, which is what somebody types. A name is not typeable and an address
    /// is not either, and a handle belongs to a **membership** rather than to a person, so the same
    /// person may be `seb` in one team and `sebdd` in another. **No addresses here**: a share-link
    /// guest reads this snapshot too, and a directory of every member's email would be a way for
    /// somebody outside the team to collect them by typing `@`.
    ///
    /// Empty when the machine has not been told yet, which is a real state rather than an empty
    /// team: a `send` addressed to somebody is refused while it lasts, and it ends by itself.
    public var members: [MemberRecord]

    public init(workspace: WorkspaceRecord, chats: [ChatRecord], presence: [PresenceRecord], cursor: Int64,
                composerDefaults: ComposerControlsRecord, members: [MemberRecord] = []) {
        self.workspace = workspace
        self.chats = chats
        self.presence = presence
        self.cursor = cursor
        self.composerDefaults = composerDefaults
        self.members = members
    }

    enum CodingKeys: String, CodingKey {
        case workspace, chats, presence, cursor, members
        case composerDefaults = "composer_defaults"
    }

    /// **A field this build requires is a workspace an older machine cannot open.**
    ///
    /// The asymmetry is deliberate and is the same one `composer_defaults` already taught us: a
    /// **server** is held to sending every field the schema says it sends, and a **client** is held
    /// to reading what a machine in the field actually sends, which is whatever was true when that
    /// machine was built. Every machine running today was made before `members` existed, and a
    /// synthesised decoder throws on a key that is not there: not "a workspace with no names in it"
    /// but **"that workspace will not open"**, which is how a small addition becomes an outage.
    ///
    /// Written out rather than left to the property's default, because a default on a stored
    /// property is not what `Decodable` uses for a missing key. That is the trap, and it is silent
    /// until somebody opens an older machine.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.decode(WorkspaceRecord.self, forKey: .workspace)
        chats = try container.decode([ChatRecord].self, forKey: .chats)
        presence = try container.decode([PresenceRecord].self, forKey: .presence)
        cursor = try container.decode(Int64.self, forKey: .cursor)
        composerDefaults = try container.decode(ComposerControlsRecord.self, forKey: .composerDefaults)
        members = try container.decodeIfPresent([MemberRecord].self, forKey: .members) ?? []
    }
}

/// Somebody with access to this workspace, for addressing a message to them.
public struct MemberRecord: Codable, Sendable, Hashable {
    public var userID: String
    public var name: String
    /// What somebody types after `@`. Short, stable, and unique inside this team.
    public var handle: String

    public init(userID: String, name: String, handle: String) {
        self.userID = userID
        self.name = name
        self.handle = handle
    }

    enum CodingKeys: String, CodingKey {
        case name, handle
        case userID = "user_id"
    }
}

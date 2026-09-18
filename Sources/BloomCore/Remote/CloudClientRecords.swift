import BloomProtocol
import Foundation

// The version 1 wire records turned into the core values the Mac's transcript, composer and
// questions already draw, for a client reading a Cloud workspace. The other direction, core to
// wire, is `RemoteRecords.swift`, which the server writes with; these are its inverses, kept apart
// because the server never reads a record back into a chat and a client never writes one.
//
// **Nothing here is stored.** A Cloud workspace's messages never enter this Mac's database: a
// `Message` made here lives in a transcript model and nowhere else, which is also why its id is
// handed in rather than taken from the record. See `CloudMessageIdentity`.

extension Session {
    /// A chat on a machine, as the transcript and the composer read a `Session`.
    ///
    /// `workspaceID` is nil, because the workspace is not a row here. The state is the machine's,
    /// and an unknown one reads as idle rather than failing the whole chat.
    public init(cloudChat record: ChatRecord) {
        let agent = AgentKind.named(wire: record.agent) ?? .claudeCode
        self.init(
            id: SessionID(record.id),
            workspaceID: nil,
            parentSessionID: record.parentChatID.map(SessionID.init),
            title: record.title,
            model: record.model,
            effort: record.effort,
            agentKind: agent,
            permissionMode: PermissionMode(rawValue: record.permissionMode) ?? AppDefaults.fallbackPermissionMode,
            interactionMode: InteractionMode(rawValue: record.interactionMode) ?? .build,
            state: SessionState(rawValue: record.state) ?? .idle,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            lastReadSeq: record.lastSeq
        )
    }
}

extension Message {
    /// A transcript row off the wire. The payload goes back to the bytes the agent wrote: a row
    /// the server could not parse as JSON travels as a string, and is handed back as that text.
    public init(cloudMessage record: MessageRecord, id: Int64) {
        let payload: Data = if case .string(let text) = record.payload { Data(text.utf8) } else { record.payload.data }
        self.init(
            id: id,
            sessionID: SessionID(record.chatID),
            seq: record.seq,
            kind: MessageKind(rawValue: record.kind) ?? .notice,
            payload: payload,
            createdAt: record.createdAt,
            durationMS: record.durationMS,
            refID: record.refID,
            author: record.author.map { MessageAuthor(userID: $0.userID, name: $0.name) }
        )
    }
}

extension ChangedFile {
    /// A changed file off the wire, for the inspector, which draws the same rows for both kinds of
    /// workspace. The inverse of `record(contentRevision:)` above it.
    ///
    /// `layer` is read rather than dropped, though no scope the machine measures separates staged
    /// from unstaged work today: `discard_hunk` already names a layer, so the day the snapshot does
    /// too the rows arrive with it. A name this version does not know reads as no layer.
    public init(cloudRecord record: ChangedFileRecord) {
        self.init(
            path: record.path,
            oldPath: record.oldPath,
            change: Change(wireName: record.change) ?? .modified,
            additions: record.additions,
            deletions: record.deletions,
            isBinary: record.isBinary,
            layer: record.layer.flatMap(ChangeLayer.init(rawValue:))
        )
    }
}

extension BranchCommit {
    /// One commit of the branch's history as the machine measured it, for the History tab, which
    /// draws the same rows for both kinds of workspace.
    ///
    /// `pushed` is left on the record. It is a fact a local workspace has no way to be asked for,
    /// and nothing draws it yet; putting it on this type would be inventing a field for one side.
    public init(cloudRecord record: CommitRecord) {
        self.init(sha: record.sha, subject: record.subject, author: record.authorName, date: record.date,
                  body: record.body, parents: record.parents, authorEmail: record.authorEmail)
    }
}

extension PullRequest {
    /// The pull request as the machine reports it, which is what `gh pr view` told it on the
    /// workspace's own branch.
    ///
    /// Four fields, because four is what the machine sends. Checks are `.unavailable` rather than
    /// `.none`: `.none` is a claim that the repository has no checks, and this record says nothing
    /// either way. Everything else keeps its default, so a bar drawn from this says what it knows
    /// and offers nothing that depends on what it does not.
    public init(cloudRecord record: PullRequestRecord, branch: String) {
        self.init(
            number: record.number,
            title: record.title,
            url: record.url,
            state: record.state.uppercased(),
            checks: .unavailable,
            branch: branch
        )
    }
}

extension ChangedFile.Change {
    /// The inverse of `wireName`. Nil for a letter this version does not know, which the caller
    /// reads as a modification rather than dropping the row.
    public init?(wireName: String) {
        switch wireName {
        case "added": self = .added
        case "modified": self = .modified
        case "deleted": self = .deleted
        case "renamed": self = .renamed
        case "copied": self = .copied
        case "untracked": self = .untracked
        default: return nil
        }
    }
}

extension ComposerControls {
    /// The wire's spelling of these controls, for `set_composer` and `new_chat`.
    public var cloudRecord: ComposerControlsRecord { record }

    /// Controls read off the wire. Nil for an agent this Mac does not know, which a newer machine
    /// could offer; the composer then keeps what it had.
    public static func cloud(_ record: ComposerControlsRecord) -> ComposerControls? {
        try? ComposerControls(record: record)
    }
}

extension PermissionDecision {
    /// The answer as the wire spells it.
    public var cloudAnswer: Answer {
        switch self {
        case .allow(.once): .allowOnce
        case .allow(.session): .allowSession
        case .allow(.project): .allowProject
        case .answer(let input): .question(input: input.wireValue)
        case .approvePlan(let mode): .approvePlan(permissionMode: mode.rawValue)
        case .deny(let message, let endsTurn): .deny(message: message, endsTurn: endsTurn)
        }
    }
}

/// Presentation ids for rows that never had a database id on this Mac.
///
/// The transcript's caches key rows by `Message.id`, and a local row's id is its SQLite rowid, so
/// a Cloud row cannot use its own cursor: cursor 12 on a machine and rowid 12 here are two rows
/// with one id in one cache. Every Cloud row gets a negative id instead, handed out once per
/// workspace and cursor for the life of the process, which no local row can ever have and no two
/// Cloud rows share.
@MainActor
public final class CloudMessageIdentity {
    private static var next: Int64 = -1
    private static var issued: [String: Int64] = [:]

    public static func id(workspace: CloudWorkspaceID, cursor: Int64) -> Int64 {
        let key = "\(workspace.rawValue):\(cursor)"
        if let existing = issued[key] { return existing }
        let id = next
        next -= 1
        issued[key] = id
        return id
    }
}

extension Delivery {
    /// A prompt waiting in a machine's queue, drawn as the Mac draws its own pending bubbles.
    ///
    /// The queue is the machine's, so nothing here is claimed, retried or cancelled locally: the
    /// state only decides the caption. `uncertain` is a prompt that may have reached the agent
    /// before the server stopped, and `blocked` is one runbloom.app refused to start, which keeps
    /// its limit and sentence for the caption to say.
    public init(cloudPrompt record: QueuedPromptRecord, chatID: String) {
        self.init(
            id: DeliveryID(record.id),
            targetSessionID: SessionID(chatID),
            body: record.text,
            createdAt: record.createdAt,
            state: record.state == "uncertain" ? .uncertain : .pending,
            author: record.author.map { MessageAuthor(userID: $0.userID, name: $0.name) },
            block: record.blocked.map { DeliveryBlock(limit: $0.limit, message: $0.message) }
        )
    }
}

/// What the foot of a Cloud chat's queue says, which is the machine's queue rather than this
/// Mac's, so none of `DeliveryHold`'s local reasons apply.
public enum CloudQueueCaption {
    /// - Parameter isSettingUp: whether the machine is still making itself, which the workspace
    ///   snapshot says without anybody asking the queue. **The first thing the owner met on a new
    ///   Cloud workspace was a message of his sitting under nothing at all**: the machine had
    ///   accepted it, the queue held it with no error, and every other branch here is about a
    ///   reason the machine gave. Setup is a reason nobody has to give, because the summary already
    ///   carries it, and "still starting" is the true answer for the minutes it takes.
    public static func sentence(
        first: Delivery?, isRunning: Bool, isAwaitingAnswer: Bool, queueError: String?, isSettingUp: Bool = false
    ) -> String? {
        guard let first else { return nil }
        if isSettingUp, first.block == nil, first.state != .uncertain {
            return "This Cloud workspace is still setting up. Your message goes to the agent as soon as it is ready."
        }
        if let block = first.block {
            let tail = block.clearsByItself
                ? "It goes by itself once another Cloud workspace in your team goes to sleep."
                : "It stays queued until the limit is lifted."
            return "\(block.message) \(tail)"
        }
        if first.state == .uncertain {
            return "This may already have reached the agent before the Cloud workspace stopped. Remove it if the conversation shows it did."
        }
        if let queueError, !queueError.isEmpty {
            return "Paused: \(queueError) Send another message to carry on."
        }
        if isAwaitingAnswer { return "Goes once the question above is answered." }
        if isRunning { return "Goes when this turn ends." }
        return nil
    }
}

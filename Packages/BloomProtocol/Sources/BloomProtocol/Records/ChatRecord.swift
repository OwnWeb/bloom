import Foundation

/// One conversation in the workspace.
///
/// `agent` is `claude`, `codex` or `grok`, the names runbloom.app uses. `state` is `idle`,
/// `running`, `waiting`, `failed` or `cancelled`. `parent_chat_id` is set for a subagent another
/// chat started.
public struct ChatRecord: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var agent: String
    public var model: String
    public var effort: String
    public var permissionMode: String
    public var interactionMode: String
    public var state: String
    public var parentChatID: String?
    public var lastSeq: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, title: String, agent: String, model: String, effort: String, permissionMode: String,
        interactionMode: String, state: String, parentChatID: String? = nil, lastSeq: Int, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.interactionMode = interactionMode
        self.state = state
        self.parentChatID = parentChatID
        self.lastSeq = lastSeq
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, agent, model, effort, state
        case permissionMode = "permission_mode"
        case interactionMode = "interaction_mode"
        case parentChatID = "parent_chat_id"
        case lastSeq = "last_seq"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// One transcript row.
///
/// `seq` orders rows within a chat. `cursor` orders rows across the whole workspace and is what
/// the event stream's `id:` carries, because a workspace holds several chats and a per-chat
/// number cannot say where a reconnect should resume.
///
/// **`payload` is a Claude Code `stream-json` line, whatever agent produced the turn.** Codex and
/// Grok are translated into that shape at ingest, before the row is written, so a client writes
/// one renderer rather than three. The reason is the store rather than the client: a row is read
/// back by one decoder that knows one vocabulary, and a JSON-RPC notification kept as it arrived
/// draws perfectly while it is live and comes back after a restart as a column of unknown rows.
/// `CodexTranslation` and `GrokTranslation` are where it happens, and `docs/CODEX.md` says why.
///
/// The one per-agent difference is inside that shape, and it is the tool vocabulary. Codex keeps
/// its own names, because `Shell` is not `Bash` and `ApplyPatch` is not `Edit`: they are different
/// tools with different rules, and a permission grant has to read back as the thing the person
/// actually approved. The native item travels under `input.codexItem`, so a presenter can tell
/// which vocabulary a row is in from the row alone and nothing is lost.
/// `Protocol/v1/stored-payloads.json` is what both look like, written out of the real translators.
public struct MessageRecord: Codable, Sendable, Hashable {
    public var cursor: Int64
    public var chatID: String
    public var seq: Int
    public var kind: String
    public var payload: WireValue
    public var author: AuthorRecord?
    public var createdAt: Date
    public var durationMS: Int?
    public var refID: String?
    /// Who it was for. Absent means the agent, which is every message sent before mentions existed.
    /// See `AudienceRecord`.
    public var audience: AudienceRecord?

    public init(
        cursor: Int64, chatID: String, seq: Int, kind: String, payload: WireValue, author: AuthorRecord? = nil,
        createdAt: Date, durationMS: Int? = nil, refID: String? = nil, audience: AudienceRecord? = nil
    ) {
        self.cursor = cursor
        self.chatID = chatID
        self.seq = seq
        self.kind = kind
        self.payload = payload
        self.author = author
        self.createdAt = createdAt
        self.durationMS = durationMS
        self.refID = refID
        self.audience = audience
    }

    enum CodingKeys: String, CodingKey {
        case cursor, seq, kind, payload, author, audience
        case chatID = "chat_id"
        case createdAt = "created_at"
        case durationMS = "duration_ms"
        case refID = "ref_id"
    }
}

/// A prompt waiting its turn.
///
/// `state` is `queued`, `blocked` (runbloom.app refused to start it, and `blocked` says why) or
/// `uncertain` (it may have reached the agent before the server stopped, so it is not sent again
/// without a person deciding).
public struct QueuedPromptRecord: Codable, Sendable, Hashable {
    public var id: String
    public var text: String
    public var author: AuthorRecord?
    public var state: String
    public var blocked: BlockedRecord?
    public var createdAt: Date

    public init(id: String, text: String, author: AuthorRecord?, state: String, blocked: BlockedRecord? = nil, createdAt: Date) {
        self.id = id
        self.text = text
        self.author = author
        self.state = state
        self.blocked = blocked
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, text, author, state, blocked
        case createdAt = "created_at"
    }
}

/// Why a prompt cannot start: the limit runbloom.app named and the sentence it wrote.
public struct BlockedRecord: Codable, Sendable, Hashable {
    public var limit: String
    public var message: String

    public init(limit: String, message: String) {
        self.limit = limit
        self.message = message
    }
}

/// A chat's queue, and why it is not moving when it is not.
public struct QueueRecord: Codable, Sendable, Hashable {
    public var chatID: String
    public var prompts: [QueuedPromptRecord]
    public var error: String?

    public init(chatID: String, prompts: [QueuedPromptRecord], error: String? = nil) {
        self.chatID = chatID
        self.prompts = prompts
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case prompts, error
        case chatID = "chat_id"
    }
}

/// A permission prompt, question or plan waiting for somebody to answer it.
///
/// `ask` is a Claude Code `can_use_tool` control request, for the same reason a message payload is
/// a `stream-json` line: Codex's five approval kinds and Grok's are translated into that envelope
/// before the question is stored, so one decoder redraws a workspace reopened mid question. Which
/// backend asked is read off the tool name, which stays that backend's own.
public struct QuestionRecord: Codable, Sendable, Hashable {
    public var requestID: String
    public var chatID: String
    public var ask: WireValue
    public var askedAt: Date

    public init(requestID: String, chatID: String, ask: WireValue, askedAt: Date) {
        self.requestID = requestID
        self.chatID = chatID
        self.ask = ask
        self.askedAt = askedAt
    }

    enum CodingKeys: String, CodingKey {
        case ask
        case requestID = "request_id"
        case chatID = "chat_id"
        case askedAt = "asked_at"
    }
}

/// One page of a chat's history, with the live state a client needs to draw it.
public struct TranscriptRecord: Codable, Sendable, Hashable {
    public var chat: ChatRecord
    public var messages: [MessageRecord]
    /// Whether more rows follow the last one in this page.
    public var hasMore: Bool
    public var questions: [QuestionRecord]
    public var busy: Bool
    public var streamingText: String
    public var queue: QueueRecord

    public init(chat: ChatRecord, messages: [MessageRecord], hasMore: Bool, questions: [QuestionRecord], busy: Bool, streamingText: String, queue: QueueRecord) {
        self.chat = chat
        self.messages = messages
        self.hasMore = hasMore
        self.questions = questions
        self.busy = busy
        self.streamingText = streamingText
        self.queue = queue
    }

    enum CodingKeys: String, CodingKey {
        case chat, messages, questions, busy, queue
        case hasMore = "has_more"
        case streamingText = "streaming_text"
    }
}

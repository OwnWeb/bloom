import Foundation

/// One event on `GET /_bloom/v1/events`, which is ordinary server-sent events: `event:` is the
/// kind, `data:` is this value as JSON, and `id:` is set on `message` events only.
///
/// **The `id:` is a transcript cursor and nothing else.** A reconnect sends it back as
/// `Last-WorkspaceEvent-ID` and is sent every row after it, so a machine that paused and woke costs a
/// client nothing it already had. Everything that is state rather than history (the queue,
/// questions, the composer, streaming text, presence, setup) is sent whole when a stream opens and
/// then as it changes, so none of it needs a cursor of its own.
public enum WorkspaceEvent: Codable, Sendable, Hashable {
    /// A transcript row was written.
    case message(MessageRecord)
    /// Streaming text for a running turn. `snapshot` is the whole text so far, sent when a stream
    /// opens; otherwise `text` is appended to what the client has.
    case stream(chatID: String, text: String, snapshot: Bool)
    /// A chat was created, renamed, closed or changed state.
    case chat(ChatRecord)
    /// A chat's queue changed.
    case queue(QueueRecord)
    /// The questions waiting in a chat changed.
    case questions(chatID: String, questions: [QuestionRecord])
    /// A chat's composer was set, and by whom.
    case composer(chatID: String, controls: ComposerControlsRecord, changedBy: AuthorRecord?)
    /// Setup moved to another step or state.
    case setup(SetupRecord)
    /// Setup wrote output.
    case setupOutput(text: String)
    /// The changes on disk moved, so a review should ask for a new snapshot.
    case review(revision: Int)
    /// An agent on the machine is **asking** for a browser pane. No url means this workspace's own
    /// public address, which a client connected to it already knows. Not an
    /// instruction: a client shows it, ignores it, or is not there at all.
    ///
    /// **The machine cannot open a pane and this is how it says so usefully.** A pane belongs to
    /// the window of whoever is looking, which is on somebody's Mac; the machine can only ask, and
    /// it may be asking nobody. The tool that sends this tells the agent how many clients were
    /// told, so an agent never reports opening something that did not open.
    case paneRequested(url: String?, chatID: String?)
    /// Who has the workspace open.
    case presence([PresenceRecord])
    /// The workspace's name, branch or pull request changed.
    case workspace(WorkspaceRecord)
    /// The machine is about to sleep. The stream closes after this; a client reconnects on the
    /// next thing a person does.
    case sleeping
    /// The stream is closing for a reason the client has to act on: `token_expired`,
    /// `unauthenticated` when access was revoked, or `unavailable` on shutdown.
    case closing(WireError)

    public var kind: String {
        switch self {
        case .message: "message"
        case .stream: "stream"
        case .chat: "chat"
        case .queue: "queue"
        case .questions: "questions"
        case .composer: "composer"
        case .setup: "setup"
        case .setupOutput: "setup_output"
        case .review: "review"
        case .paneRequested: "pane_requested"
        case .presence: "presence"
        case .workspace: "workspace"
        case .sleeping: "sleeping"
        case .closing: "closing"
        }
    }

    /// The SSE `id:`, for the events a reconnect resumes by.
    public var cursor: Int64? {
        if case .message(let message) = self { message.cursor } else { nil }
    }

    enum Keys: String, CodingKey {
        case chatID = "chat_id", text, snapshot, questions, controls, changedBy = "changed_by", revision, users, error, url
    }

    public init(from decoder: any Decoder) throws {
        let kind = try Tagged.kind(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        switch kind {
        case "message": self = .message(try Tagged.record(MessageRecord.self, kind: kind, from: decoder))
        case "stream":
            self = .stream(chatID: try c.decode(String.self, forKey: .chatID), text: try c.decode(String.self, forKey: .text),
                           snapshot: try c.decodeIfPresent(Bool.self, forKey: .snapshot) ?? false)
        case "chat": self = .chat(try Tagged.record(ChatRecord.self, kind: kind, from: decoder))
        case "queue": self = .queue(try Tagged.record(QueueRecord.self, kind: kind, from: decoder))
        case "questions": self = .questions(chatID: try c.decode(String.self, forKey: .chatID), questions: try c.decode([QuestionRecord].self, forKey: .questions))
        case "composer":
            self = .composer(chatID: try c.decode(String.self, forKey: .chatID), controls: try c.decode(ComposerControlsRecord.self, forKey: .controls),
                             changedBy: try c.decodeIfPresent(AuthorRecord.self, forKey: .changedBy))
        case "setup": self = .setup(try Tagged.record(SetupRecord.self, kind: kind, from: decoder))
        case "setup_output": self = .setupOutput(text: try c.decode(String.self, forKey: .text))
        case "review": self = .review(revision: try c.decode(Int.self, forKey: .revision))
        case "pane_requested":
            self = .paneRequested(url: try c.decodeIfPresent(String.self, forKey: .url),
                                  chatID: try c.decodeIfPresent(String.self, forKey: .chatID))
        case "presence": self = .presence(try c.decode([PresenceRecord].self, forKey: .users))
        case "workspace": self = .workspace(try Tagged.record(WorkspaceRecord.self, kind: kind, from: decoder))
        case "sleeping": self = .sleeping
        case "closing": self = .closing(try c.decode(WireError.self, forKey: .error))
        default: throw Tagged.unknown(kind, in: decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .message(let value): try Tagged.encode(kind: kind, to: encoder, record: value)
        case .stream(let chatID, let text, let snapshot):
            try Tagged.encode(kind: kind, to: encoder)
            try c.encode(chatID, forKey: .chatID); try c.encode(text, forKey: .text); try c.encode(snapshot, forKey: .snapshot)
        case .chat(let value): try Tagged.encode(kind: kind, to: encoder, record: value)
        case .queue(let value): try Tagged.encode(kind: kind, to: encoder, record: value)
        case .questions(let chatID, let questions):
            try Tagged.encode(kind: kind, to: encoder)
            try c.encode(chatID, forKey: .chatID); try c.encode(questions, forKey: .questions)
        case .composer(let chatID, let controls, let changedBy):
            try Tagged.encode(kind: kind, to: encoder)
            try c.encode(chatID, forKey: .chatID); try c.encode(controls, forKey: .controls); try c.encodeIfPresent(changedBy, forKey: .changedBy)
        case .setup(let value): try Tagged.encode(kind: kind, to: encoder, record: value)
        case .setupOutput(let text): try Tagged.encode(kind: kind, to: encoder); try c.encode(text, forKey: .text)
        case .review(let revision): try Tagged.encode(kind: kind, to: encoder); try c.encode(revision, forKey: .revision)
        case .paneRequested(let url, let chatID):
            try Tagged.encode(kind: kind, to: encoder)
            try c.encodeIfPresent(url, forKey: .url); try c.encodeIfPresent(chatID, forKey: .chatID)
        case .presence(let users): try Tagged.encode(kind: kind, to: encoder); try c.encode(users, forKey: .users)
        case .workspace(let value): try Tagged.encode(kind: kind, to: encoder, record: value)
        case .sleeping: try Tagged.encode(kind: kind, to: encoder)
        case .closing(let error): try Tagged.encode(kind: kind, to: encoder); try c.encode(error, forKey: .error)
        }
    }
}

/// The text frames on the terminal WebSocket. Output and keystrokes are binary frames.
///
/// The first frame a client sends is `auth`, because a browser's `WebSocket` cannot send an
/// `Authorization` header; the server closes a connection that has not authenticated within five
/// seconds. `reauth` carries a fresh token before the current one expires.
public enum TerminalControlFrame: Codable, Sendable, Hashable {
    case auth(token: String)
    case reauth(token: String)
    case resize(columns: Int, rows: Int)

    enum Keys: String, CodingKey { case token, columns, rows }

    public init(from decoder: any Decoder) throws {
        let kind = try Tagged.kind(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        switch kind {
        case "auth": self = .auth(token: try c.decode(String.self, forKey: .token))
        case "reauth": self = .reauth(token: try c.decode(String.self, forKey: .token))
        case "resize": self = .resize(columns: try c.decode(Int.self, forKey: .columns), rows: try c.decode(Int.self, forKey: .rows))
        default: throw Tagged.unknown(kind, in: decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .auth(let token): try Tagged.encode(kind: "auth", to: encoder); try c.encode(token, forKey: .token)
        case .reauth(let token): try Tagged.encode(kind: "reauth", to: encoder); try c.encode(token, forKey: .token)
        case .resize(let columns, let rows):
            try Tagged.encode(kind: "resize", to: encoder); try c.encode(columns, forKey: .columns); try c.encode(rows, forKey: .rows)
        }
    }
}

/// The body of `POST /_bloom/v1/streams/{id}/token`, a fresh token for an open event stream.
public struct StreamTokenRecord: Codable, Sendable, Hashable {
    public var token: String
    public init(token: String) { self.token = token }
}

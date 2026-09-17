import BloomProtocol
import Foundation

/// Everything a client knows about one open Cloud workspace, built from the `workspace` read,
/// transcript pages and the event stream, in whatever order they arrive.
///
/// A value, and every change goes through `apply`, `absorb` or `absorbPage`, so the merging rules of
/// the client chapter in docs/WORKSPACE-PROTOCOL.md are tested here rather than in a window:
///
/// - a chat's rows are ordered by `seq`, and a row that arrives twice (in a page and as an event)
///   is the same row, kept once;
/// - a row that arrives as an event before the page that should hold it is kept, and the page
///   fills in around it;
/// - the largest cursor seen across every chat is where the next stream resumes;
/// - streaming text is replaced by a snapshot, appended to otherwise, and dropped when the
///   assistant's row arrives.
public struct CloudWorkspaceState: Sendable, Hashable {
    public var workspace: WorkspaceRecord?
    public var chats: [String: CloudChatState] = [:]
    /// Chat ids in the order the workspace listed them, with chats created later at the end.
    public var chatOrder: [String] = []
    public var presence: [PresenceRecord] = []
    public var setup: SetupRecord?
    public var setupLog = ""
    /// Bumped by a `review` event; the review asks for a new snapshot when it moves.
    public var reviewRevision = 0
    /// Where the next event stream resumes.
    public private(set) var cursor: Int64?

    public init() {}

    /// Chats a person talks to, oldest first: subagents are drawn inside their parent.
    public var topLevelChats: [ChatRecord] {
        chatOrder.compactMap { chats[$0]?.chat }.filter { $0.parentChatID == nil }
    }

    // MARK: Reads

    /// The `workspace` read: the header, every chat, presence, and the cursor a stream opened now
    /// resumes after.
    public mutating func absorb(_ snapshot: WorkspaceSnapshotRecord) {
        apply(.workspace(snapshot.workspace))
        for chat in snapshot.chats { upsert(chat) }
        presence = snapshot.presence
        advance(to: snapshot.cursor)
    }

    /// One transcript page. Answers the `after_seq` of the next page, or nil when there is none.
    @discardableResult
    public mutating func absorbPage(_ page: TranscriptRecord) -> Int? {
        upsert(page.chat)
        var chat = chats[page.chat.id] ?? CloudChatState(chat: page.chat)
        for message in page.messages { chat.insert(message) }
        chat.questions = page.questions
        chat.queue = page.queue
        chat.busy = page.busy
        chat.streamingText = page.busy ? page.streamingText : ""
        let last = page.messages.map(\.seq).max()
        if !page.hasMore { chat.hasReadHistory = true }
        chats[page.chat.id] = chat
        for message in page.messages { advance(to: message.cursor) }
        return page.hasMore ? last : nil
    }

    // MARK: Events

    /// What an event changed, beyond the state itself, that a client reacts to.
    public enum Consequence: Sendable, Hashable {
        case none
        /// The machine is going to sleep and the stream is about to close.
        case sleeping
        /// The stream is closing for this reason.
        case closing(WireError)
        /// The review should ask for a new snapshot.
        case reviewMoved
        /// Somebody other than the reader changed a chat's composer.
        case composerChanged(chatID: String, by: AuthorRecord?)
        /// A chat this client had not seen appeared, so its history should be read.
        case newChat(String)
    }

    @discardableResult
    public mutating func apply(_ event: WorkspaceEvent) -> Consequence {
        switch event {
        case .message(let message):
            var chat = chats[message.chatID] ?? CloudChatState(id: message.chatID)
            chat.insert(message)
            if message.kind == "assistantText" || message.kind == "result" { chat.streamingText = "" }
            chats[message.chatID] = chat
            if !chatOrder.contains(message.chatID) { chatOrder.append(message.chatID) }
            advance(to: message.cursor)
        case .stream(let chatID, let text, let snapshot):
            var chat = chats[chatID] ?? CloudChatState(id: chatID)
            chat.streamingText = snapshot ? text : chat.streamingText + text
            chats[chatID] = chat
        case .chat(let record):
            let isNew = chats[record.id]?.chat == nil
            upsert(record)
            if isNew { return .newChat(record.id) }
        case .queue(let queue):
            chats[queue.chatID, default: CloudChatState(id: queue.chatID)].queue = queue
        case .questions(let chatID, let questions):
            chats[chatID, default: CloudChatState(id: chatID)].questions = questions
        case .composer(let chatID, let controls, let changedBy):
            chats[chatID, default: CloudChatState(id: chatID)].controls = controls
            chats[chatID]?.controlsChangedBy = changedBy
            return .composerChanged(chatID: chatID, by: changedBy)
        case .setup(let record):
            setup = record
            workspace?.setup = record
        case .setupOutput(let text):
            setupLog += text
            // Setup output is a log to read, not a record to keep: the head of a very long one
            // goes, so a workspace left open through a noisy setup does not grow without bound.
            if setupLog.utf8.count > Self.setupLogLimit {
                setupLog = String(setupLog.suffix(Self.setupLogLimit / 2))
            }
        case .review(let revision):
            reviewRevision = revision
            return .reviewMoved
        case .presence(let users):
            presence = users
        case .workspace(let record):
            workspace = record
            setup = record.setup
        case .sleeping:
            return .sleeping
        case .closing(let error):
            return .closing(error)
        }
        return .none
    }

    /// Records the cursor of a frame that could not be decoded, so a reconnect does not ask for it
    /// again.
    public mutating func skip(cursor: Int64?) {
        if let cursor { advance(to: cursor) }
    }

    static let setupLogLimit = 1_000_000

    private mutating func upsert(_ record: ChatRecord) {
        var chat = chats[record.id] ?? CloudChatState(chat: record)
        chat.chat = record
        // A chat's state is the only word on whether its turn ended that an event carries, so it
        // settles `busy` too. A transcript page read after it says the same thing more precisely.
        chat.busy = record.state == "running" || record.state == "waiting"
        chats[record.id] = chat
        if !chatOrder.contains(record.id) { chatOrder.append(record.id) }
    }

    private mutating func advance(to value: Int64) {
        if cursor.map({ value > $0 }) ?? true { cursor = value }
    }
}

/// One chat inside `CloudWorkspaceState`.
public struct CloudChatState: Sendable, Hashable {
    public var id: String
    /// Nil only for a chat an event named before its record arrived.
    public var chat: ChatRecord?
    /// Ordered by `seq`, each `seq` once.
    public private(set) var messages: [MessageRecord] = []
    public var hasReadHistory = false
    public var streamingText = ""
    public var busy = false
    public var queue: QueueRecord
    public var questions: [QuestionRecord] = []
    public var controls: ComposerControlsRecord?
    public var controlsChangedBy: AuthorRecord?

    public init(id: String) {
        self.id = id
        queue = QueueRecord(chatID: id, prompts: [])
    }

    public init(chat: ChatRecord) {
        self.init(id: chat.id)
        self.chat = chat
    }

    /// The newest `seq` held, or -1 for none, which is what the next page's `after_seq` is.
    public var lastSeq: Int { messages.last?.seq ?? -1 }

    /// Inserts a row in `seq` order. A second copy of a `seq` replaces nothing: a row never changes
    /// once written, so the first copy is as good as any.
    mutating func insert(_ message: MessageRecord) {
        if let last = messages.last, last.seq < message.seq {
            messages.append(message)
            return
        }
        var low = 0
        var high = messages.count
        while low < high {
            let middle = (low + high) / 2
            if messages[middle].seq < message.seq { low = middle + 1 } else { high = middle }
        }
        if low < messages.count, messages[low].seq == message.seq { return }
        messages.insert(message, at: low)
    }

    /// Whether the chat is doing something a person would wait for: a turn, or a queue that will
    /// start one.
    public var isRunning: Bool { busy || chat?.state == "running" }
}

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
    /// What a chat that does not exist yet would open with, as this machine answers it.
    ///
    /// **On the workspace, not under a chat, and that is the point rather than a detail.** The
    /// machine answers `composer` for a new chat with no `chat_id` at all, because there is no chat
    /// to name. Filing it under a made-up key would collide with a real chat the day the machine
    /// shortens its ids, and the collision would show somebody another chat's settings, which is
    /// the sort of bug nobody goes looking for. It is a property of the workspace because that is
    /// what it is about.
    ///
    /// Nil for a machine too old to send it, which is a fallback rather than a failure: see
    /// `WorkspaceSnapshotRecord.composerDefaults`.
    public var composerDefaults: ComposerControlsRecord?
    /// Who may be addressed with `@` in this workspace, as the machine lists them. Empty until it
    /// has been told, which is a state rather than an empty team: see `MemberRecord`.
    public var members: [MemberRecord] = []

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
        if let defaults = snapshot.composerDefaults { composerDefaults = defaults }
        members = snapshot.members
        advance(to: snapshot.cursor)
    }

    /// One transcript page. Answers the `after_seq` of the next page, or nil when there is none.
    ///
    /// **Only its rows are taken.** A page is as old as the moment it was read, and the stream may
    /// have moved on while it travelled: a turn that ended, a question answered, a queue that
    /// emptied. The stream sends all of that whole when it opens and as it changes, so the page's
    /// copy of it could only ever put something stale back. Its chat record is taken only for a
    /// chat the stream has not described yet.
    @discardableResult
    public mutating func absorbPage(_ page: TranscriptRecord) -> Int? {
        if chats[page.chat.id]?.chat == nil { upsert(page.chat) }
        chats[page.chat.id, default: CloudChatState(chat: page.chat)].insert(contentsOf: page.messages)
        if !page.hasMore { chats[page.chat.id]?.hasReadHistory = true }
        for message in page.messages { advance(to: message.cursor) }
        return page.hasMore ? page.messages.map(\.seq).max() : nil
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
        /// The agent asked for a browser pane. A request rather than an instruction: see
        /// `WorkspaceEvent.paneRequested` and `CloudPaneRequest`.
        case paneRequested(url: String?, chatID: String?)
        /// A chat stopped running, which is the moment its workspace's changes went stale.
        ///
        /// Running to anything else, including waiting for an answer: an agent that stops to ask a
        /// question has already written whatever it wrote before asking, and the reader looking at
        /// the question is the one most likely to look at the diff next.
        case turnEnded(chatID: String)
    }

    @discardableResult
    public mutating func apply(_ event: WorkspaceEvent) -> Consequence {
        switch event {
        case .message(let message):
            // In place, so the dictionary's copy is the only one and a long chat's rows are not
            // copied for every row that arrives.
            chats[message.chatID, default: CloudChatState(id: message.chatID)].insert(message)
            if message.kind == "assistantText" || message.kind == "result" { chats[message.chatID]?.streamingText = "" }
            if !chatOrder.contains(message.chatID) { chatOrder.append(message.chatID) }
            advance(to: message.cursor)
        case .stream(let chatID, let text, let snapshot):
            chats[chatID, default: CloudChatState(id: chatID)].appendStreaming(text, snapshot: snapshot)
        case .chat(let record):
            let isNew = chats[record.id]?.chat == nil
            let wasRunning = chats[record.id]?.chat?.state == "running"
            upsert(record)
            if isNew { return .newChat(record.id) }
            if wasRunning, record.state != "running" { return .turnEnded(chatID: record.id) }
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
        case .paneRequested(let url, let chatID):
            // Nothing is kept: a request is a moment rather than state, and a client that was not
            // listening when it was made has not missed a fact about the workspace.
            return .paneRequested(url: url, chatID: chatID)
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
    /// The machine could not replay everything after the cursor the client asked from, so the
    /// client has a gap it cannot see. Advancing alone would leave that gap in the transcript for
    /// good, so every chat is marked unread as well: `insert` is keyed by `seq`, so reading a
    /// history again costs requests and changes nothing that was already right.
    public mutating func skip(cursor: Int64?) {
        if let cursor { advance(to: cursor) }
        for id in chats.keys { chats[id]?.hasReadHistory = false }
    }

    /// The whole log as `setup_output` read it, which replaces what the stream had appended.
    public mutating func replaceSetupLog(_ log: String, setup record: SetupRecord) {
        setupLog = log.utf8.count > Self.setupLogLimit ? String(log.suffix(Self.setupLogLimit / 2)) : log
        setup = record
        workspace?.setup = record
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

    mutating func insert(contentsOf rows: [MessageRecord]) {
        for row in rows { insert(row) }
    }

    mutating func appendStreaming(_ text: String, snapshot: Bool) {
        streamingText = snapshot ? text : streamingText + text
    }

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

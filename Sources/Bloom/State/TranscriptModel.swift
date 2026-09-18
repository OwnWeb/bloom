import SwiftUI
import Observation
import BloomCore
import BloomClient
import BloomProtocol

/// One renderable row in a transcript.
///
/// It deliberately carries the raw JSON rather than a decoded structure. The store keeps every
/// event verbatim, so a renderer added later can show detail that was not decoded when the row
/// was written, and a row costs nothing to hold until it scrolls into view.
struct TranscriptRow: Identifiable, Hashable, Sendable {
    var id: Int64
    var seq: Int
    var kind: MessageKind
    var payload: Data
    var createdAt: Date
    var durationMS: Int?
    var refID: String?

    /// Set once the matching tool_result arrives, so a tool call and its outcome render as one row.
    var resultPayload: Data?
    var isError = false
    /// Set when the result says the call never ran, and why. A refusal carries `is_error` as well,
    /// so the two are held together and every reader that draws a failure checks this first.
    var refusal: ToolRefusal?
    /// The one line the CLI gave for a refusal, so a collapsed row can say what happened without
    /// decoding a result payload that is usually the largest in the session.
    var refusalReason = ""
    /// Non-nil when the row came from inside a subagent, so it can be indented under its parent.
    var parentToolUseID: String?

    /// For a `permissionAsk` row: how the question was settled, or nil while it is still open.
    ///
    /// Held on the row rather than looked up per frame, because the answer decides whether the row
    /// draws live buttons, and a row that offers buttons for a question already answered would
    /// write into a pipe nobody is reading.
    var permissionDecision: String?
    /// Questions and their answers are conversation content, even after their controls settle.
    /// Decoded when the row arrives so folding never reparses the question on a render pass.
    var isQuestion = false
    /// What the transcript should say about how it was settled, when that is not obvious. Only
    /// ever set for a question a rule answered rather than a person.
    var permissionNote = ""
    /// Who wrote a user row in a Cloud workspace, when it was somebody other than the reader. Nil
    /// everywhere else, which is every local row: a Mac has one person at it.
    ///
    /// The name may be empty where the account has none, and an empty label is drawn as no label:
    /// see `UserTurnRowView`. The colour of the bubble does not depend on it, which is what stops
    /// a nameless teammate from being read as yourself.
    var authorName: String?
    /// Which account that was, for telling one run of messages from the next. The name would
    /// nearly always do and is the wrong key: two people called Freek are two people.
    var authorID: String?

    init(message: Message) {
        id = message.id
        seq = message.seq
        kind = message.kind
        payload = message.payload
        createdAt = message.createdAt
        durationMS = message.durationMS
        refID = message.refID
        authorName = message.author?.name
        authorID = message.author?.userID
    }

    /// This row in the only terms `TranscriptFold` cares about.
    ///
    /// Here rather than inside `TranscriptModel.presentationFolds`, where it was written, because
    /// the subagent pane folds its rows too and a second copy of what counts as settled or featured
    /// is a subagent pane that folds differently from the chat the day one of them changes.
    ///
    /// - Parameters:
    ///   - seq: the identity the fold names a run by. The row's own `seq` for a stored row; the
    ///     subagent pane passes its payload derived id, because its positions move on a re-read.
    ///   - isFresh: a tool call made moments ago. Only the live chat knows, so it is handed in.
    nonisolated func foldFact(seq: Int? = nil, isFresh: Bool = false) -> TranscriptFold.Fact {
        let settled: Bool
        switch kind {
        case .toolUse: settled = resultPayload != nil
        case .permissionAsk: settled = permissionDecision != nil
        default: settled = true
        }
        return TranscriptFold.Fact(
            seq: seq ?? self.seq,
            kind: kind,
            failed: isError || refusal != nil,
            featured: isQuestion
                || MediaShowRow.isCall(payload) || CodexImageViewRow.isCall(payload),
            drawsNothing: TranscriptNoise.isHidden(self)
                || TranscriptRowInk.drawsNothing(kind: kind, payload: payload),
            settled: settled,
            isFresh: isFresh,
            toolUseID: kind == .toolUse ? refID : nil,
            parentToolUseID: parentToolUseID,
            opensTurn: BackgroundWake.isRow(kind: kind, payload: payload)
        )
    }
}

/// The state behind one session's transcript: the rows, whether the agent is running, and the
/// partial text currently streaming in.
@MainActor
@Observable
final class TranscriptModel {
    private struct RunnerPreferences: Equatable {
        var model: String
        var effort: String
        var permissionMode: String
        var agentKind: String

        init(session: Session) {
            model = session.model
            effort = session.effort
            permissionMode = session.permissionMode.rawValue
            agentKind = session.agentKind.rawValue
        }
    }

    var session: Session
    let history = TranscriptHistory()
    /// The workspace as it was when this model was made, or nil for a chat that is in none.
    ///
    /// **Nil is a chat with no worktree on this Mac: Ask Bloom, and a chat in a Cloud workspace.**
    /// A workspace's id and path are stable and are what most of the file needs; its name is not,
    /// and anything said out loud reads `workspaceNow`. Every reader of this is a thing a worktree
    /// has and these chats do not: an inspector, a diff, an unread mark, a notification that names
    /// a place, and the setup row at the head of the transcript, which is why a Cloud workspace's
    /// setup is its own tab and its own banner rather than a row in a conversation. Each of them
    /// says nothing rather than saying it about a workspace invented to keep the type non-optional.
    let workspace: Workspace?
    /// Where this chat's agent runs: its worktree, or the directory retained by its Ask tab.
    /// New Ask conversations use the folder chosen in Settings, with Bloom's own folder as fallback.
    let cwd: String
    private unowned let app: AppModel
    /// The machine this chat lives on, for a chat in a Cloud workspace, and nil for every other.
    ///
    /// **A Cloud chat has no store.** Its rows, queue and questions are the machine's, and they
    /// arrive through `receiveCloud`; `store` below answers nil for it, which is what switches off
    /// every local read and write in this file without a branch at each one. What it does have is
    /// a handful of verbs that go to the machine instead: see the Cloud section at the foot.
    let cloud: CloudChatLink?

    /// Where this conversation's file paths point, and which workspace a file chip opens into.
    /// One value rather than the whole workspace, because those two fields are all a row has ever
    /// read off it. See `TranscriptHome`.
    var home: TranscriptHome {
        TranscriptHome(
            workspaceID: workspace?.id,
            surfaceID: workspace.map { .local($0.id) } ?? cloud?.workspaceID.map { .cloud($0) },
            worktree: cwd
        )
    }

    /// The row as the app holds it now. The snapshot above goes stale the moment automatic
    /// naming lands, minutes into the workspace's life, and every alert and notification from
    /// this chat then called the workspace by its ocean placeholder for the rest of the launch.
    private var workspaceNow: Workspace? {
        guard let workspace else { return nil }
        return app.existingModel(for: workspace.id)?.workspace ?? workspace
    }

    private(set) var rows: [TranscriptRow] = []
    /// Changes to presentation facts include edits to existing tool and permission rows.
    private(set) var presentationRevision = 0
    @ObservationIgnored private var foldCache = TranscriptFoldCache()
    @ObservationIgnored private var questionIndex = PinnedQuestionIndex()
    /// Tool calls that arrived moments ago, by call id, which fold before their result is back.
    /// See `TranscriptFold.freshCall`. Told through `presentationRevision`, like the cache above.
    @ObservationIgnored private var freshCalls: Set<String> = []

    /// These caches write no observable state and are safe to consult during a render pass.
    /// Each belongs to this session, including when its pane is displaying another workspace.
    func presentationFolds() -> TranscriptFold.Folds {
        let freshCalls = freshCalls
        return foldCache.resolve(rows.lazy.map { row in
            row.foldFact(
                isFresh: row.kind == .toolUse && row.refID.map(freshCalls.contains) == true
            )
        })
    }

    /// Every prompt in the session, for the turn minimap. The same incremental index the pinned
    /// question reads, so a body asking for this on each pass pays only for rows that are new.
    func turns() -> [PinnedQuestion] {
        questionIndex.update(session: session.id, rows: rows)
        return questionIndex.all
    }

    func pinnedQuestion(atOrBefore seq: Int) -> PinnedQuestion? {
        questionIndex.update(session: session.id, rows: rows)
        return questionIndex.latest(atOrBefore: seq)
    }

    /// Whether this session's agent is mid turn.
    ///
    /// Computed over one stored flag rather than being the stored flag, so that every change to
    /// it goes through `setRunning` and the app can be told. Reading it still registers a
    /// dependency on `storedIsRunning`, which is what a view needs.
    var isRunning: Bool { storedIsRunning }
    private var storedIsRunning = false

    /// Whether this session's agent has stopped and is waiting on a person.
    ///
    /// A stored flag for exactly the reason `isRunning` is one, and not a walk over `rows` looking
    /// for an unanswered question. `rows` is observable, so a derived answer would technically
    /// invalidate, but it would also be recomputed on every streamed token of every turn, and the
    /// readers that need this (the sidebar mark, the Dock badge, the menu bar count) are not in a
    /// position to walk anything: see `AppModel.waitingWorkspaceIDs`.
    var isAwaitingPermission: Bool { storedIsAwaitingPermission }
    private var storedIsAwaitingPermission = false
    private(set) var isLoaded = false

    /// How full the model's context window is, as of the newest row that said anything about it.
    ///
    /// Stored for exactly the reason `isAwaitingPermission` is stored, and the composer is exactly
    /// the reader that argument was written for. It used to be derived in the composer's own body
    /// from `rows`, which is observed, so every row appended during a turn invalidated the whole
    /// composer subtree: the box, the chips, the footer and its four menus, once per streamed
    /// block. And the walk itself could not stop early when there was no answer to find, because
    /// the limit only ever arrives on the line that closes a turn, so a session that had never
    /// finished one walked the entire transcript on every pass to return nil. Keeping the answer
    /// removes the walk and the dependency together. See `ContextWindowUsage.updated`.
    private(set) var contextUsage: ContextWindowUsage?

    /// Text and thinking arriving live, before the completed block is persisted.
    private(set) var streamingText = ""
    private(set) var streamingThinking = ""
    @ObservationIgnored private(set) var messageArrivals = MessageArrivals()
    private(set) var streamingToolName: String?
    private(set) var thinkingTokens = 0
    private(set) var statusLabel: String?

    /// The turn waiting out an outage, while it is waiting.
    ///
    /// Live state rather than rows, for the reason on `AgentRetry`: ten announcements about one
    /// stuck request are one fact, and nine tenths of it is stale by the time the tenth arrives.
    /// Cleared the moment anything else arrives, which is what makes the handover to the error row
    /// clean: a turn that runs out of attempts ends with its failure drawn once, not with a
    /// waiting row still sitting above it saying it is about to try again.
    private(set) var retryRun: RetryRun?

    /// Turns that waited and then got through, keyed by the `seq` of the result row that closed
    /// them, so the footer can account for the minutes.
    ///
    /// **This is what happens to the waiting row when it succeeds.** It does not simply vanish,
    /// because then nothing explains why a turn took three minutes; and it does not stay as it
    /// was, because a warning plate over a turn that is fine is a lie. It collapses to one quiet
    /// sentence under the turn, in the footer's own ink. In memory only: a transcript reopened
    /// tomorrow has the duration and no explanation, which is where it was before any of this.
    private(set) var recoveredRuns: [Int: RetryRun] = [:]

    /// The subagents this session has spawned and not yet accounted for, in spawn order.
    ///
    /// One roster per session rather than per workspace, because a workspace with four chats runs
    /// four turns and the sidebar draws the active chat's. It is deliberately not stored: see
    /// `SubagentRoster` for the argument, which is that the longest one of these is meant to live
    /// is a single session and the CLI's own record of it is already on disk.
    private(set) var subagents = SubagentRoster() {
        didSet {
            if let id = workspace?.id { app.noteSubagentsChanged(workspaceID: id) }
            if oldValue.isWorking != subagents.isWorking { app.noteAgentTurnsChanged() }
            let note = BackgroundWork.note(for: subagents)
            if note != backgroundWork { backgroundWork = note }
        }
    }

    /// What the agent left running when its turn ended, named, for the last turn's footer.
    ///
    /// Stored rather than read off `subagents` by the transcript, because the roster moves on every
    /// `tool_progress` tick, about once a second per subagent, and the transcript's table reading
    /// it would rebuild on each one. This moves only when the sentence does. See `BackgroundWork`.
    private(set) var backgroundWork: String?

    var draft = ""

    /// How far Up and Down have walked back through this session's sent prompts. On the session
    /// rather than in the composer's state, because one composer is handed from session to session
    /// as a pane changes what it shows. See `PromptRecall`.
    @ObservationIgnored var promptRecall = PromptRecall()

    /// What has been asked for on this session and has not gone yet, oldest first.
    ///
    /// Read by the transcript to draw the pending bubbles and by the drain to decide what goes
    /// next. It mirrors the `deliveries` table rather than being the queue itself: the table is
    /// the queue, because a message somebody typed has to survive quitting Bloom. See `Delivery`.
    private(set) var pendingDeliveries: [Delivery] = []

    /// The sentence that is on its way to the agent and has no `messages` row yet.
    ///
    /// **This is the instant echo, and it exists because pressing Return drew nothing at all.**
    /// The runner writes the user row as part of `send`, and the transcript only ever read rows
    /// back when an agent event arrived, so the owner's own message did not appear until the
    /// answer began. Every call to `appendLatestMessages` sat inside `handle(_:)`, and the two
    /// events that arrive before the model says anything, `initialized` and `status`, are not
    /// among the cases that call it: the earliest his own sentence could reach the screen was the
    /// agent's first word about it. That was true before the queue landed and is not a regression
    /// of it.
    ///
    /// So the moment something is submitted with nothing holding the queue, it is held here and
    /// drawn as an ordinary user bubble, in `UserTurnRowView`, with the same text and the same
    /// numbers the stored row will use. It is cleared by the user row arriving, in `absorb`, so
    /// the drawing is replaced by an identical drawing in one pass and nothing moves. A message
    /// that is NOT free to go is not held here: it stays in `pendingDeliveries` and is drawn as
    /// the pending bubble, which says why it is waiting. `Delivery.goesImmediately` is the one
    /// place that decision is taken, and the drain asks the same function.
    private(set) var sending: Delivery?

    /// The queue as the transcript draws it: everything still waiting, and never the one already
    /// drawn as a sent bubble. The drain reads `pendingDeliveries`, which is the table, because
    /// what may be delivered is not a question about what is on screen.
    var waitingDeliveries: [Delivery] {
        guard let sending else { return pendingDeliveries }
        return pendingDeliveries.filter { $0.id != sending.id }
    }

    /// Whether this chat has nothing on screen at all, counting a sentence on its way out and a
    /// sentence waiting in the queue as things on screen. An empty state drawn over either of
    /// them is an empty state drawn over the one thing the owner is looking for.
    var hasNothingToShow: Bool {
        rows.isEmpty && sending == nil && pendingDeliveries.isEmpty
    }

    /// Whether the turn that is ending was ended by a person pressing Stop.
    ///
    /// Stop is not "next, please". Somebody who stops an agent is stepping in, and firing the
    /// message they queued four minutes ago into the silence they just made is the opposite of
    /// what they asked for. A cancelled turn still emits its own result (see `stop()`), so the
    /// drain hanging off that result has to be able to tell the two endings apart. Cleared when a
    /// turn starts, so it never outlives the turn it describes.
    private var wasStoppedByHand = false
    @ObservationIgnored private var drainState = DeliveryDrainState.idle

    /// The queued message a Steer has picked, waiting for the turn it stopped to finish dying.
    ///
    /// **Held rather than sent on the button press, for the reason `drain` is called from the
    /// result rather than from `stop`.** A cancelled turn still emits its own result, and that
    /// event is where a turn actually ends: it clears the streaming tail, files the run and sets
    /// `isRunning` false. A send racing it would start the steered turn and then have the dying
    /// turn's result switch it off again, leaving a composer that says nothing is running over an
    /// agent that is. So Steer books the message here and the one place that decides what happens
    /// when a turn ends sends it. Cleared there, and wherever the chat stops expecting a result.
    private var steering: Delivery?

    /// Whether the chat above this one has already been told that this turn ended.
    ///
    /// A turn has two endings that report, `.error` and `.result`, and they are not alternatives:
    /// `AgentRunner` yields `.error(.storage(...))` when a transcript write fails without ending
    /// the turn, so the failure sentence went out and then the turn's own result went out behind
    /// it. An orchestrator told twice that one agent stopped picks the work back up twice, on the
    /// first sentence and then again on a second that says the same thing. Cleared where a turn
    /// begins, so it never silences the next one.
    private var hasReportedTurnEnded = false

    /// Bumped whenever something outside the list asks it to go back to the newest row. A counter
    /// rather than a flag, so two requests in a row are two requests, and the list has nothing to
    /// clear afterwards. See `jumpToLiveEnd`.
    private(set) var liveEndRequests = 0

    /// Bumped when something outside the composer has put words in the draft that the owner is
    /// meant to carry on writing. A counter for `liveEndRequests`'s reason: two requests in a row
    /// are two requests, and the composer has nothing to clear afterwards.
    private(set) var composerFocusRequests = 0
    /// Where the last of those requests wants the caret. See `focusComposer(caretAtEnd:)`.
    @ObservationIgnored private(set) var composerFocusCaretAtEnd = false

    /// A passage of an answer, quoted at the end of the draft with the caret left under it.
    func appendQuote(_ selection: String) {
        guard let quoted = ReplyQuote.appending(selection, to: draft) else { return }
        draft = quoted
        focusComposer(caretAtEnd: true)
    }

    func appendSourceContext(_ context: String) {
        draft += (draft.isEmpty ? "" : "\n\n") + "Ask about this code:\n\n" + context + "\n\n"
        focusComposer()
    }

    /// - Parameter caretAtEnd: whether the caret goes after what arrived rather than before it. A
    ///   queued message brought back to edit wants the start, a quote wants the line under it.
    func focusComposer(caretAtEnd: Bool = false) {
        composerFocusCaretAtEnd = caretAtEnd
        composerFocusRequests += 1
    }

    private var isReconcilingPresentation = false
    private var isReplayingPastTurn = false
    private var presentationMessageSeq: Int?
    private var dispatchingDeliveryID: DeliveryID?
    private var activeInteractionMode: InteractionMode?
    private var runner: (any SessionRunner)?
    @ObservationIgnored private var idleEvictionTask: Task<Void, Never>?

    func codexSubagentTranscript(for id: SubagentID) async -> SubagentTranscript? {
        guard let codex = runner as? CodexRunner else { return nil }
        return await codex.subagentTranscript(for: id)
    }
    private var pumpTask: Task<Void, Never>?
    /// Preferences are captured when a runner is created. Comparing them at delivery time avoids
    /// reusing a process after the picker changed, even when persistence is still catching up.
    private var runnerPreferences: RunnerPreferences?
    private var indexByRefID: [String: Int] = [:]
    /// The one read of this session's history, held so that it happens once however many callers
    /// ask for it.
    ///
    /// Two of them do, and both arrive before it has finished: `WorkspaceModel.transcript(for:)`
    /// reads a model eagerly the moment it builds one, and `TranscriptListView`'s own task reads it
    /// again when the pane draws. `isLoaded` cannot keep them apart, since it is only true on the
    /// last line of the read. `SingleFlight` is named after, and documents, the transcript that
    /// would not draw when the two of them ran the read at once.
    private let loader = SingleFlight()
    /// The newest stored message this model has ingested, whether or not that message became a
    /// row. Tool results fold into their tool-use row, so the rendered rows cannot answer this
    /// without both walking the whole transcript and still sometimes returning an older sequence.
    /// Outside observation because it is only a database cursor and nothing draws it.
    @ObservationIgnored private var highestSeenMessageSeq = -1
    /// When the current turn was handed to the runner, so a session row written before that can be
    /// recognised as belonging to the previous turn.
    private var turnStartedAt: Date?

    /// An old result must not hide the live tail of a turn the agent has just started itself.
    func isCurrentTurnResult(_ row: TranscriptRow) -> Bool {
        row.kind == .result && (!isRunning || turnStartedAt.map { row.createdAt >= $0 } ?? true)
    }

    init(session: Session, workspace: Workspace, app: AppModel) {
        self.session = session
        self.workspace = workspace
        self.cwd = workspace.path
        self.app = app
        cloud = nil
        history.report = { [unowned app] in app.notice = BloomNotice(message: $0) }
    }

    /// The conversation that belongs to Bloom rather than to a workspace.
    ///
    /// A second initialiser rather than an optional argument on the one above, because the two
    /// disagree about what `cwd` is and a caller passing nil to the first would have had to know
    /// to pass a directory as well. See `AskConversation`.
    init(askSession session: Session, directory: String, app: AppModel) {
        self.session = session
        self.workspace = nil
        self.cwd = directory
        self.app = app
        cloud = nil
        history.report = { [unowned app] in app.notice = BloomNotice(message: $0) }
    }

    /// A chat in a Cloud workspace, which lives on its machine. See `cloud`.
    init(cloudChat session: Session, link: CloudChatLink, app: AppModel) {
        self.session = session
        self.workspace = nil
        // No worktree on this Mac. A file chip in a Cloud row names a path on the machine, which
        // an empty home leaves unresolved rather than pointing at whatever this Mac has there.
        self.cwd = ""
        self.app = app
        cloud = link
        isLoaded = true
    }

    private var store: Store? { cloud == nil ? app.store : nil }

    // MARK: - Loading

    func load() async {
        guard let store, !isLoaded else {
            SwitchTrace.mark("transcript.reused", workspace: workspace?.id)
            SwitchTrace.markOnScreen("transcript.reused", workspace: workspace?.id)
            return
        }
        // Whichever of the two callers gets here first does the reading, and the other waits on it.
        // The guard above cannot tell them apart, because neither of them is reusing anything: they
        // are both asking for the same session's history at the same moment.
        await loader.run { [self] in await read(from: store) }
    }

    /// The read itself, reached only through `loader`.
    ///
    /// The rows are built into a list off to one side and put on the model in one assignment at the
    /// end, rather than the model's own list being emptied and then filled. There is an await in
    /// the middle of this and there will probably be another one day, and a half built row list
    /// must never be observable: a `ForEach` handed rows whose identifiers repeat lays them out in
    /// whatever order it pleases, and that is what left an answer undrawn until the scroller was
    /// dragged.
    private func read(from store: Store) async {
        SwitchTrace.mark("transcript.read.start", workspace: workspace?.id)
        let messages = (try? await store.messages(sessionID: session.id)) ?? []
        SwitchTrace.mark("transcript.read.done", workspace: workspace?.id)
        // Read once for the whole session rather than per row: a transcript can hold thousands of
        // rows and at most a handful of them are questions.
        let decisions = (try? await store.permissionAskDecisions(sessionID: session.id)) ?? [:]

        // Off the main actor, and not for tidiness. The fold below is the one place in the app
        // that JSON-parses a whole session in one go: `ParentProbe.parentToolUseID` materialises
        // every message's payload to read one top level key, `ToolResultSummary.decode` does it
        // again for every tool result, which is the largest payload in the file, and
        // `PermissionAsk.decode` a third time for every question. Measured with `--switch-probe`
        // on a release build against the 1,306 message workspace: 35ms of main thread between
        // `transcript.read.start` and `transcript.rows.built`, in the middle of the wait between
        // clicking a workspace in the sidebar and seeing it.
        //
        // It is safe to move because it was already written to be moved. `absorb` is static and
        // folds into a list handed to it rather than into the model's own, which is what the
        // paragraph at the head of this function is about, so nothing observable exists until the
        // assignment below.
        let built = await Task.detached(priority: .userInitiated) {
            var rows: [TranscriptRow] = []
            var index: [String: Int] = [:]
            var highestMessageSeq = -1
            for message in messages {
                highestMessageSeq = max(highestMessageSeq, message.seq)
                Self.absorb(message, decisions: decisions, into: &rows, indexByRefID: &index)
            }
            return (rows: rows, index: index, highestMessageSeq: highestMessageSeq)
        }.value

        foldCache.reset()
        freshCalls = []
        questionIndex = PinnedQuestionIndex()
        rows = built.rows
        presentationRevision += 1
        indexByRefID = built.index
        highestSeenMessageSeq = built.highestMessageSeq

        // The parsing every row of the window is about to want, done now and off this thread. See
        // `TranscriptPrime`, which is where the whole argument for it is. Nothing cancels it: it
        // is one window of a session that has just been asked for, at `.utility`, and a handle
        // nobody would ever call `cancel` on is bookkeeping.
        let unread = firstUnreadSeq
        Task.detached(priority: .utility) { [rows = built.rows, worktree = cwd] in
            await TranscriptPrime.run(rows: rows, worktree: worktree, unreadSeq: unread)
        }

        // Stays on the main actor, and can afford to: it walks backwards and stops as soon as it
        // has both numbers, which is within a few rows of the end whatever the session's length.
        //
        // The one place the whole list is walked, because it is also the one place there is a
        // whole list to walk. Everything after this folds in what arrived. Nothing is held from
        // before: this is a session being read from the start.
        contextUsage = ContextWindowUsage.latest(in: built.rows)
        SwitchTrace.mark("transcript.rows.built", workspace: workspace?.id)
        SwitchTrace.markOnScreen("transcript.rows.built", workspace: workspace?.id)

        draft = (try? await store.draft(sessionID: session.id)) ?? ""
        // Read, and deliberately not drained. A message queued before the last quit must not
        // start a paid turn on a Mac nobody is sitting at, so it is shown as pending and goes with
        // the owner's next message. See `DeliveryHold.none`.
        await refreshQueue()
        await history.load(store: store, sessionID: session.id)
        isLoaded = true
    }

    /// Folds a stored message into the row list, pairing tool results onto their tool call.
    ///
    /// Handed the list and the reference index it is folding into rather than reaching for the
    /// model's own, so that the same rule can build a whole session's rows somewhere nothing can
    /// see them. See `read(from:)` for why that matters.
    /// Nonisolated, so `read(from:)` can run the whole session's worth of it off the main actor.
    /// It touches nothing but its arguments, which is what made the move a two line change.
    nonisolated private static func absorb(
        _ message: Message,
        decisions: [String: String],
        into rows: inout [TranscriptRow],
        indexByRefID: inout [String: Int]
    ) {
        if message.kind == .toolResult, let refID = message.refID,
           let index = indexByRefID[refID] {
            rows[index].resultPayload = message.payload
            let summary = ToolResultSummary.decode(message.payload)
            rows[index].isError = summary.isError
            rows[index].refusal = summary.refusal
            rows[index].refusalReason = summary.reason
            if let duration = message.durationMS { rows[index].durationMS = duration }
            return
        }

        var row = TranscriptRow(message: message)
        row.parentToolUseID = ParentProbe.parentToolUseID(message.payload)
        if message.kind == .permissionAsk,
           let ask = PermissionAsk.decode(payload: message.payload) {
            row.permissionDecision = decisions[ask.requestID]
            row.isQuestion = ask.isQuestion
        }
        rows.append(row)
        if message.kind == .toolUse, let refID = message.refID {
            indexByRefID[refID] = rows.count - 1
        }
    }

    /// The same fold, over messages that were never stored.
    ///
    /// **The subagent pane draws a conversation and had grown a renderer of its own to do it.** A
    /// subagent's lines come back from `SubagentTranscript` in the shape the store hands a message
    /// back in, so they are folded with this rule rather than with a second one: which result
    /// belongs to which call, what a refusal is and how long a call took are decided here for
    /// every conversation in the window, and a second copy of that is a second copy to keep right.
    ///
    /// No decisions, because a subagent is never asked a permission question: the CLI puts those
    /// on the parent's stream, where the transcript already answers them.
    nonisolated static func rows(from messages: [Message]) -> [TranscriptRow] {
        var built: [TranscriptRow] = []
        var indexByRefID: [String: Int] = [:]
        for message in messages {
            Self.absorb(message, decisions: [:], into: &built, indexByRefID: &indexByRefID)
        }
        return built
    }

    /// The same fold, straight onto the model, for the rows that arrive while the session is open.
    private func absorb(_ message: Message, decisions: [String: String] = [:]) {
        messageArrivals.persisted(seq: message.seq, kind: message.kind, sending: sending?.id)
        let changedIndex = message.kind == .toolResult
            ? message.refID.flatMap { indexByRefID[$0] } ?? rows.count : rows.count
        foldCache.invalidate(row: changedIndex)
        Self.absorb(message, decisions: decisions, into: &rows, indexByRefID: &indexByRefID)
        presentationRevision += 1
        // The stored row has arrived, so the bubble drawn from the queue is now the same sentence
        // drawn twice. Retired here rather than after the send returns, because the pump can read
        // the row first: only one turn is ever in flight, so a user row landing while something is
        // sending is that sentence. See `sending`.
        //
        // A crew row is the same retirement for a message an agent wrote: the runner records it
        // as `.crew` instead of `.user`. Checking only `.user` left a message from another
        // workspace drawn a second time, as the owner's teal bubble under the turn it started,
        // until something else cleared the slot. Only when what is sending IS a crew message,
        // because Bloom writes some crew rows directly, and one of those landing mid send must not
        // take the owner's own sentence off the screen early.
        if message.kind == .user || (message.kind == .crew && sending?.crewMessage != nil) {
            sending = nil
        }
    }

    /// The turn somebody stopped, named by the `seq` of the row that closed it.
    ///
    /// A stop is a fact about the chat rather than about a row: `SessionState.cancelled` says the
    /// last turn was ended by hand, and the state leaves `cancelled` the moment another turn
    /// starts, so the stop can only ever be about the last one. Derived here rather than written
    /// into `messages` for the reason `WorkspaceEvent`'s header sets out: a row Bloom writes about
    /// a turn would be read back by whatever assembles a prompt, and a note to the person is not
    /// something the agent should be told. Derived also means it is simply gone when the next turn
    /// starts, instead of being a stale second line left behind for ever.
    ///
    /// Nil when the stop left no result row at all, which `StoppedTurn` explains.
    var stoppedTurnSeq: Int? {
        guard session.state == .cancelled else { return nil }
        // Lazily, so a session of thousands of rows is not copied into an array of kinds to answer
        // a question the last two or three rows settle.
        guard let index = StoppedTurn.closingRow(in: rows.lazy.map(\.kind)) else { return nil }
        return rows[index].seq
    }

    // MARK: - Unread

    var firstUnreadSeq: Int? {
        rows.first { $0.seq > session.lastReadSeq }?.seq
    }

    func markAllRead() async {
        if let cloud {
            guard let last = rows.last?.seq, last != session.lastReadSeq else { return }
            // Moved only once the machine took it, so a mark made while the workspace could not be
            // reached is made again next time rather than lost.
            if await cloud.markRead(seq: last) { session.lastReadSeq = last }
            return
        }
        guard let store, let last = rows.last?.seq, last != session.lastReadSeq else { return }
        session.lastReadSeq = last
        try? await store.updateLastReadSeq(sessionID: session.id, seq: last)
    }

    /// Pulls the session row back from the store. Anything the runner owns (the agent session
    /// id, the state, the counters) only ever travels in this direction.
    func refreshSession() async {
        guard let store, let fresh = try? await store.session(id: session.id) else { return }
        session = fresh
        // The runner owns the state column, and it writes a terminal state from paths that do not
        // always reach the UI as an event. Trusting the row here is what keeps the composer from
        // spinning against an agent that is already gone. A row last written before the current
        // turn started still describes the previous one, so it says nothing about this turn.
        let isStale = turnStartedAt.map { fresh.updatedAt < $0 } ?? false
        if !isStale, fresh.state == .failed || fresh.state == .cancelled {
            setRunning(false)
            statusLabel = nil
        }
    }

    /// The pickers in the composer write through here so they touch only their own columns.
    func updatePreferences(
        title: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil,
        interactionMode: InteractionMode? = nil,
        implementationMode: PermissionMode? = nil,
        agentKind: AgentKind? = nil
    ) async {
        if let cloud {
            await updateCloudPreferences(
                through: cloud, model: model, effort: effort, permissionMode: permissionMode,
                interactionMode: interactionMode, agentKind: agentKind
            )
            return
        }
        guard let store else { return }
        try? await store.updateSessionPreferences(
            id: session.id,
            title: title,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            interactionMode: interactionMode,
            implementationMode: implementationMode,
            agentKind: agentKind
        )
        await refreshSession()
    }

    /// Asks the list to go back to the newest row.
    ///
    /// The live end rather than a row, and that is the whole of what changed here. This used to
    /// name `firstUnreadSeq` and scroll to it, which asks the list for a position inside its lazy
    /// stack, and a stack that is drawing the end of a long session does not necessarily hold that
    /// row yet. An edge needs no identity and is always there.
    func jumpToLiveEnd() {
        liveEndRequests += 1
    }

    // MARK: - Sending

    /// Everything anybody says to this chat, and the only way in.
    ///
    /// **One ordered queue, because there used to be two paths and they raced.** The prompt typed
    /// in the create window waited inside the setup task; anything typed into the composer during
    /// that minute went straight to the runner, since nothing marks a session busy while its
    /// worktree is being built. The owner opened a workspace asking for one thing, typed a second
    /// thing while the script ran, and watched the second one answered first. Nothing about that
    /// was fixable by hurrying one of the two paths along: whichever continuation the scheduler
    /// reached first won, so the fix is that there is one path and it has an order.
    ///
    /// So this never sends. It joins the queue and then asks the queue to move, which is also what
    /// makes the invariant cheap to state: what is delivered is delivered in the order it was
    /// asked for, whatever asked for it. See `Delivery`.
    ///
    /// **It also draws the sentence before it awaits anything**, which is the whole of the instant
    /// echo. Enqueueing is two round trips to a SQLite actor that a diff refresh or an archive can
    /// be sitting in front of, and handing the line to the runner is a process launch behind that.
    /// None of it is work the owner should watch an empty transcript through, so the message is on
    /// screen from the frame the key went down, in the state `Delivery.goesImmediately` says it is
    /// in: as a sent bubble if nothing is holding the queue, as a pending one if something is. See
    /// `sending`.
    @discardableResult
    func submit(_ text: String, clearingDraft sourceDraft: String? = nil,
                interactionMode: InteractionMode? = nil, sourcePlan: PlanArtefact? = nil) async -> Bool {
        guard !isWorkspaceArchiving else { return false }
        if usesInteractiveTerminal {
            app.alert = BloomAlert(
                title: "This agent runs in a terminal",
                message: "Open its agent tab and enter the prompt in the CLI."
            )
            return false
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cloud { return await submitToCloud(body, through: cloud, sourceDraft: sourceDraft) }
        guard !body.isEmpty, let store else { return false }

        // Review payloads expand compact chips into comments. Clear the source draft, while
        // retaining anything the reader typed after that payload began being prepared.
        let submittedDraft = SubmittedDraft.matching(current: draft, message: body, source: sourceDraft)
        if submittedDraft != nil { draft = "" }

        // Built here rather than inside the enqueue, so the row that goes in the table and the
        // bubble that goes on screen are one object with one id. Drawn twice under two ids is the
        // duplicate that would appear the moment the queue was read back.
        let delivery = Delivery(targetSessionID: session.id, body: body, interactionMode: interactionMode ?? session.interactionMode)
        // Ask Bloom is the only transcript with no workspace, and the only one named this way.
        if workspace == nil {
            let id = session.id
            Task { await app.ask.nameFromFirstMessage(id, prompt: body) }
        }
        messageArrivals.sent(delivery.id)
        if queuesNextMessage || (isRunning && delivery.interactionMode != activeInteractionMode) {
            pendingDeliveries.append(delivery)
        } else {
            sending = delivery
        }

        // And the list is taken to it, on the same frame, for the same reason the bubble is drawn
        // before anything is awaited: what somebody just asked for should be the thing they are
        // looking at.
        //
        // The bug this closes was Merge. The button composes a turn and sends it down this path,
        // the transcript did not follow, and the request landed below the fold with the jump pill
        // floating over the top of it: the one thing the owner had just triggered was the one
        // thing off screen. It was never only Merge. Create pull request, Push, the continuation
        // after a merge, a review sent with comments and a reply typed into a banner all arrive
        // here, and a message typed into the composer while the reader was scrolled up did the
        // same. One queue in, one rule about where the list sits.
        //
        // `jumpToLiveEnd` rather than a scroll of its own: it is the jump pill's own request, so
        // this reuses the display-link glide in `TranscriptListView.goToLiveEnd`, which already
        // asks `TranscriptMotion` whether Reduce Motion is on and jumps instead when it is.
        jumpToLiveEnd()

        do {
            _ = try await store.enqueueDelivery(delivery, clearingDraftMatching: submittedDraft, sourcePlan: sourcePlan)
        } catch {
            // The bubble was drawn on the promise that this would be queued. It was not, so the
            // promise is taken back rather than left on screen next to a message that is never
            // going anywhere.
            if sending?.id == delivery.id { sending = nil }
            pendingDeliveries.removeAll { $0.id == delivery.id }
            draft = PendingMessageReturn.draft(taking: [delivery], into: draft)
            composerFocusRequests += 1
            await saveDraft()
            Log.composer.error(
                "the message could not be queued: \(error.readableMessage, privacy: .public)"
            )
            app.alert = BloomAlert(
                title: "Could not queue the message",
                message: TranscriptStanding.complaint(about: error)
            )
            return false
        }

        // Not from `drain`, and not before the enqueue. The owner saying something is the moment a
        // queue held over from a relaunch, or paused by a Stop, is meant to move again, and it
        // moves from the front rather than from what was just typed.
        wasStoppedByHand = false
        await drain()
        return true
    }

    /// Why the queue in front of this chat is not moving, which is both the drain's condition and
    /// the sentence the first pending bubble carries. See `DeliveryHold`.
    ///
    /// The setup half is read off the workspace's own model rather than mirrored here. Only that
    /// model runs the script, and a second copy of "is setup running" is a second thing to get
    /// wrong: the transcript already spent a release drawing "setup has not run yet" over output
    /// the script had just printed, for exactly that reason.
    var deliveryHold: DeliveryHold {
        // A chat with no worktree has no setup script to be waiting on, so both halves are
        // false and the hold can only ever be a running turn or an open question.
        let model = workspace.flatMap { app.existingModel(for: $0.id) }
        return DeliveryHold.of(
            isRunningSetup: model?.isRunningSetup ?? false,
            isTurnRunning: isRunning,
            isAwaitingQuestion: isAwaitingPermission
        )
    }

    /// Whether pressing Return right now puts the message in the queue rather than handing it over.
    ///
    /// Read by `submit` to decide which bubble to draw and by the footer to decide what the Send
    /// button's tooltip promises, so the caption over the button and the bubble under it cannot
    /// say different things. It was `isRunning` in the footer, which stopped being the same
    /// question the moment a running turn stopped holding the queue on two of the four backends:
    /// the tooltip went on offering to queue a message that was about to go straight out.
    var queuesNextMessage: Bool {
        if cloud != nil { return isRunning || isAwaitingPermission || !pendingDeliveries.isEmpty }
        if history.isCapturing || history.isFinalisingTurn || (history.hasActiveTurn && !isRunning) { return true }
        if isRunning, session.interactionMode != activeInteractionMode { return true }
        return !Delivery.goesImmediately(
            behind: pendingDeliveries, hold: deliveryHold, on: session.agentKind
        )
    }

    /// What the last pending bubble says under itself, or nothing when nothing is holding it.
    ///
    /// Here rather than in the row because it needs the chat's backend, which the row has no
    /// business knowing, and because a caption that disagrees with the drain is the one thing this
    /// queue may not do: both read `DeliveryHold`. See `DeliveryHold.sentence(on:)`.
    var holdSentence: String? {
        if cloud != nil {
            return CloudQueueCaption.sentence(
                first: pendingDeliveries.first, isRunning: isRunning, isAwaitingAnswer: isAwaitingPermission,
                queueError: cloudQueueError, isSettingUp: cloud?.isSettingUp == true
            )
        }
        if history.isCapturing || history.isFinalisingTurn { return "Saving this turn's file changes." }
        if pendingDeliveries.first?.state == .uncertain {
            return "Bloom could not confirm delivery. Check the conversation before sending again."
        }
        if isRunning, let mode = pendingDeliveries.first?.interactionMode, mode != activeInteractionMode {
            return "Goes when this turn ends."
        }
        return deliveryHold.sentence(on: session.agentKind)
    }

    /// Hands the queue to the agent, from the front, for as long as it is allowed to go.
    ///
    /// **How many leave in one pass is the backend's answer and `Delivery.deliverable` is where it
    /// is taken.** On a CLI that will not read a line written into a running turn this hands over
    /// one, because the turn that one starts holds the rest, which is what it always did. On one
    /// that will, a running turn holds nothing, so the queue empties in the order it was asked
    /// for rather than one message per turn under a caption promising a wait that is not
    /// happening.
    ///
    /// The hold is read again on every pass rather than once at the top. A permission question can
    /// arrive between two sends, and nothing may be written into a turn that is blocked on one.
    ///
    /// Called from the three moments a queue is meant to move and from nowhere else: the setup
    /// script finishing, a turn ending of its own accord, and the owner submitting. Not on launch,
    /// and not after a Stop. Both of those would spend the owner's money on a turn nobody asked
    /// for at that moment, and both are covered by the queue simply sitting there, visibly, until
    /// somebody says something.
    func drain() async {
        guard !usesInteractiveTerminal else { return }
        guard !isReconcilingPresentation else { return }
        guard !history.isCapturing, !history.isFinalisingTurn, !(history.hasActiveTurn && !isRunning) else { return }
        guard !isWorkspaceArchiving, !wasStoppedByHand, store != nil else { return }
        guard drainState.begin() else { return }
        var allowRepeat = true
        defer { finishDrain(allowRepeat: allowRepeat) }
        await refreshQueue()

        // The list is taken once and walked, rather than the queue being re-asked for a front
        // each pass. A start that fails puts its delivery back at the front (see `abandon`), so a
        // loop that asked again would hand the same message over for ever.
        for next in Delivery.deliverable(
            from: pendingDeliveries, hold: deliveryHold, on: session.agentKind
        ) {
            guard !isWorkspaceArchiving, !wasStoppedByHand,
                  deliveryHold.allowsDelivery(on: session.agentKind) else { return }
            if isRunning, let mode = next.interactionMode, mode != activeInteractionMode { return }
            // Deleted, or steered out, since the list was taken.
            guard pendingDeliveries.contains(where: { $0.id == next.id }) else { continue }

            // Drawn as said from here, whichever moment the queue is moving in: the owner
            // submitting (where `submit` has already done it, to the same id), a setup script
            // finishing, or the turn in front of it ending. Before the retire below, so there is
            // no frame on which the sentence has left the queue and has not yet become a bubble.
            // See `sending`.
            sending = next

            // Retired before it is handed over, rather than after. The pending bubble and the real
            // one are two drawings of the same sentence, and a delivery that is still pending
            // while its turn is starting is drawn twice. `restoreDelivery` is the one path back.
            guard await claimForDelivery(next) else {
                allowRepeat = false
                return
            }

            // A turn that would not start stops the pass. Its delivery is back at the front of
            // the queue with an error row under it, and pushing the next one into an agent that
            // just refused would bury that.
            guard await deliver(next) else {
                allowRepeat = false
                return
            }
        }
    }

    private func finishDrain(allowRepeat: Bool) {
        let again = drainState.finish(allowRepeat: allowRepeat)
        if again, !wasStoppedByHand, !isWorkspaceArchiving {
            Task { await drain() }
        }
    }

    private func claimForDelivery(_ delivery: Delivery) async -> Bool {
        guard let store else { return false }
        do {
            let claimed = try await store.claimDelivery(id: delivery.id)
            guard claimed else {
                if sending?.id == delivery.id { sending = nil }
                await refreshQueue()
                return false
            }
            await refreshQueue()
            if isWorkspaceArchiving || wasStoppedByHand {
                try await store.restoreDelivery(id: delivery.id)
                if sending?.id == delivery.id { sending = nil }
                await refreshQueue()
                return false
            }
            return true
        } catch {
            if sending?.id == delivery.id { sending = nil }
            app.alert = BloomAlert(
                title: "Could not send the message",
                message: TranscriptStanding.complaint(about: error)
            )
            return false
        }
    }

    /// Whether this delivery is at the front of an idle queue and can be attempted now.
    ///
    /// **Never for a Cloud chat, because there is nothing here to attempt it with.** Its queue is
    /// the machine's, `drain` returns at its own `store != nil` guard, and `retryPending` calls
    /// `drain`: the button was drawn on local-queue questions that happen to be true and then did
    /// nothing at all when pressed. The owner met that under a prompt of his that had stopped
    /// moving, which is the worst place for a control that cannot act. What the machine offers
    /// instead belongs on the machine's own verbs, and the caption is where the reason goes.
    func canRetry(_ delivery: Delivery) -> Bool {
        guard cloud == nil else { return false }
        return pendingDeliveries.first?.id == delivery.id
            && dispatchingDeliveryID != delivery.id && drainState == .idle
            && deliveryHold.allowsDelivery(on: session.agentKind)
    }

    /// Attempts the front of the queue again without changing its order or duplicating its text.
    func retryPending() async {
        guard let candidate = pendingDeliveries.first, canRetry(candidate) else { return }
        if let first = pendingDeliveries.first, first.state == .uncertain {
            do { try await store?.restoreDelivery(id: first.id) } catch { return }
            await refreshQueue()
        }
        wasStoppedByHand = false
        await drain()
    }

    /// The queued message the owner has asked to delete, and the reason the sheet is up.
    ///
    /// Here rather than in the row that draws it because the question outlives the row: the drain
    /// can retire that delivery while the sheet is open, at which point the row goes and the sheet
    /// has to be told. A `@State` inside `PendingTurnRowView` would be torn down with the row and
    /// take the dialog with it silently, which is the one outcome the race must not have.
    var discarding: Delivery?

    /// Asks before deleting, rather than deleting.
    ///
    /// The words are `PendingMessageDiscard`'s, including the promise about where the sentence
    /// ends up, so the dialog cannot promise something this object then does not do.
    func askToDiscard(_ delivery: Delivery) {
        guard dispatchingDeliveryID != delivery.id, PendingMessageDiscard.canDiscard(delivery) else { return }
        discarding = delivery
    }

    /// Takes one back out of the queue, because whoever asked for it changed their mind.
    ///
    /// The recovery is worked out here rather than when the question was asked, because the
    /// composer is live behind the sheet: what the box holds when the answer comes is what decides
    /// whether the sentence can go back into it.
    func confirmDiscard(_ delivery: Delivery) async {
        discarding = nil
        if let cloud {
            await cloud.cancelQueued(delivery.id)
            return
        }
        guard dispatchingDeliveryID != delivery.id else { return }
        guard let store else { return }
        let recovery = PendingMessageDiscard.recovery(of: delivery, composerDraft: draft)
        let removed = (try? await store.cancelDelivery(id: delivery.id)) ?? false
        await refreshQueue()

        // It went while the question was on screen. The delete loses that race on purpose: see
        // `PendingMessageDiscard.alreadySentSentence`.
        guard removed else {
            app.notice = BloomNotice(message: PendingMessageDiscard.alreadySentSentence)
            return
        }

        // A message from another workspace: the chat that sent it is waiting on an answer, and
        // has to be told there will not be one.
        if delivery.crewMessage?.event == .relayed {
            await app.noteDeliveryCancelled(delivery.id)
        }

        if case .toComposer(let text) = recovery {
            draft = text
            await saveDraft()
        }
    }

    /// Takes one back out of the queue and into the composer, to be changed before it goes.
    ///
    /// No confirmation, because nothing is lost: the words end up in the box the owner is looking
    /// at. `Store.cancelDelivery` is the same way out Delete uses, so the drain cannot fire on a
    /// message this has already handed back, and the same lost race is possible and says so.
    ///
    /// The join is worked out after the row is gone rather than before, so the words go in front
    /// of whatever the box holds by then rather than in front of what it held a round trip ago.
    func editPending(_ delivery: Delivery) async {
        if let cloud {
            // Only somebody's own message comes back into their composer. Anybody may remove a
            // queued prompt, and the machine records who did, but nobody's words are typed into
            // anybody else's box.
            guard delivery.author == nil || delivery.author?.userID == cloud.readerID else { return }
            guard await cloud.cancelQueued(delivery.id) else { return }
            draft = PendingMessageEdit.draft(taking: delivery, into: draft)
            composerFocusRequests += 1
            jumpToLiveEnd()
            return
        }
        guard dispatchingDeliveryID != delivery.id, PendingMessageEdit.canEdit(delivery), let store else { return }
        let removed = (try? await store.cancelDelivery(id: delivery.id)) ?? false
        await refreshQueue()

        guard removed else {
            app.notice = BloomNotice(message: PendingMessageEdit.alreadySentSentence)
            return
        }

        draft = PendingMessageEdit.draft(taking: delivery, into: draft)
        // Both before the write, the way `submit` draws and jumps before it awaits anything: the
        // box the words landed in is where the owner should be on that frame, not a round trip
        // later.
        composerFocusRequests += 1
        jumpToLiveEnd()
        await saveDraft()
    }

    /// Empties the queue back into the composer, because the owner stopped the turn it was
    /// waiting behind.
    ///
    /// Which messages travel, in what order, and what becomes of a draft already in the box are
    /// all `PendingMessageReturn`'s: the rule is a decision, and the suite cannot see a view.
    ///
    /// Called from `stop` and from nowhere else. Not from the result the cancellation produces:
    /// the words should be back in the box on the frame the button was pressed rather than
    /// whenever the CLI gets round to closing the turn, and doing it in both places would only be
    /// a second run finding an empty queue.
    private func returnQueueToComposer() async {
        guard let store else { return }
        await refreshQueue()
        let wanted = PendingMessageReturn.returning(from: pendingDeliveries)
        guard !wanted.isEmpty else { return }

        // One cancel each, and only what really left the queue reaches the box. A message that
        // went in the instant between the Stop and this line is a turn the agent is already
        // running, and putting its words in the composer would be offering to send it twice.
        // `Store.cancelDelivery` answering false is what tells the two apart, which is the race
        // `PendingMessageDiscard.alreadySentSentence` names. It needs no sentence here: nothing
        // was promised, and the message is on screen as an ordinary bubble that has gone.
        var returned: [Delivery] = []
        for delivery in wanted {
            let left = (try? await store.cancelDelivery(id: delivery.id)) ?? false
            guard left else { continue }
            returned.append(delivery)
        }
        await refreshQueue()
        guard !returned.isEmpty else { return }

        // The draft is read after the cancels rather than before, the way `editPending` reads it:
        // the words go in front of whatever the box holds by the time they arrive rather than in
        // front of what it held a round trip ago.
        draft = PendingMessageReturn.draft(taking: returned, into: draft)
        composerFocusRequests += 1
        await saveDraft()
    }

    /// Whether this queued message may be sent in place of the turn that is running.
    ///
    /// Two rules rather than one, because the two queues are in different places. A local queue is
    /// this app's and this Mac has one person at it; a Cloud chat's is the machine's, shared, and
    /// drained by the machine in the order it arrived. What has to be true for a cancel, a stop and
    /// a send to add up to a Steer at all is `CloudSteer`.
    func canSteer(_ delivery: Delivery) -> Bool {
        guard cloud == nil else {
            return CloudSteer.canSteer(
                isRunning: isRunning,
                // The reader's own messages carry no name: see where the queue is built.
                promptIsReaders: delivery.author == nil && delivery.crewMessage == nil,
                runningTurnIsReaders: runningTurnIsReaders,
                queued: pendingDeliveries.count
            )
        }
        return DeliverySteer.canSteer(delivery, hold: deliveryHold, on: session.agentKind)
    }

    /// Whether the turn running now was started by this reader, which is what makes stopping it
    /// theirs to do. Read off the last thing anybody said: a Cloud row carries a name when it was
    /// written by somebody else, and nothing at all when it was written here.
    private var runningTurnIsReaders: Bool {
        rows.last { $0.kind == .user }?.authorName == nil
    }

    /// Stops the turn that is running and sends this queued message into the space it makes.
    ///
    /// Everything else in the queue is left untouched, in the table, so what is still waiting
    /// waits in the order it was asked for and this one is simply no longer part of it. See
    /// `DeliverySteer.queue(after:from:)`.
    func steer(_ delivery: Delivery) async {
        guard canSteer(delivery) else { return }
        if let cloud { return await steerOnCloud(delivery, through: cloud) }
        // Booked rather than sent. See `steering` for why a send here would race the result of
        // the turn this is about to cancel.
        steering = delivery
        cancelTurn()
    }

    /// The same three words on a machine: take this message out of the queue, stop the turn, say it
    /// again now.
    ///
    /// **The order is what makes it safe.** The cancel goes first, so a machine that will not take
    /// the message back leaves the running turn alone and nothing has happened. The send goes last
    /// and is not waited for: `CloudSteer` has already established that the queue held nothing but
    /// this message, so a send that arrives while the turn is still dying is queued into an empty
    /// queue and started the moment it ends, which is the whole of what Steer promises. Waiting for
    /// the turn to die first would be a race with no benefit.
    ///
    /// A stop that fails is said and the message is still sent, because the queue it goes back into
    /// is the queue it just left: nothing is lost, and the turn simply runs on.
    private func steerOnCloud(_ delivery: Delivery, through cloud: CloudChatLink) async {
        guard await cloud.cancelQueued(delivery.id) else {
            app.alert = BloomAlert(
                title: "That message was not sent early",
                message: "The Cloud workspace would not take it back out of the queue, so the turn that is running was left alone."
            )
            return
        }
        await cloud.stop()
        // Its files are on the machine already: this text came back from there, and the paths in it
        // are the machine's. See `uploading`.
        _ = await submitToCloud(delivery.body, through: cloud, sourceDraft: nil, uploadingFiles: false)
    }

    /// Hands over the message a Steer picked, once the turn it stopped has ended.
    ///
    /// `drain`'s body with one line different, and that line is the whole feature: the message is
    /// the one that was pressed rather than the front of the queue. It goes through the same
    /// retire-then-deliver order for the same reason, which is that a delivery still marked
    /// pending while its turn is starting is drawn twice.
    private func sendSteered(_ delivery: Delivery) async {
        guard !isWorkspaceArchiving, !wasStoppedByHand, store != nil else { return }
        guard drainState.begin() else { return }
        var allowRepeat = true
        defer { finishDrain(allowRepeat: allowRepeat) }
        // A turn was started while this one was dying, which takes the owner typing into the
        // composer inside that second: `submit` drains, and the drain does not know a Steer is
        // booked. Two sends into one runner is the one outcome to avoid, and the cost of avoiding
        // it is nothing, since the message keeps its place and goes when this new turn ends.
        guard !isRunning else { return }

        await refreshQueue()
        // Deleted, or drained by something else, while the turn was dying. Nothing to say: the row
        // it was pressed on has gone, which is the whole of what happened.
        guard pendingDeliveries.contains(where: { $0.id == delivery.id }) else { return }

        sending = delivery
        guard await claimForDelivery(delivery) else {
            allowRepeat = false
            return
        }
        allowRepeat = await deliver(delivery)
    }

    /// Closes the question when the message it is about is no longer waiting.
    ///
    /// Called from `refreshQueue`, which is the one place this object learns the queue has moved.
    /// The owner is told, because a dialog that vanishes on its own reads as a bug and because
    /// what happened underneath it is exactly the thing they were trying to prevent.
    private func dropDiscardIfDelivered() {
        guard let discarding else { return }
        guard !pendingDeliveries.contains(where: { $0.id == discarding.id }) else { return }
        self.discarding = nil
        app.notice = BloomNotice(message: PendingMessageDiscard.alreadySentSentence)
    }

    /// Re-reads the queue from the table. Public because the moment a workspace's opening prompt
    /// is enqueued is outside this object, and the bubble has to be on screen from that frame.
    func refreshQueue() async {
        guard let store else { return }
        pendingDeliveries = (try? await store.pendingDeliveries(sessionID: session.id)) ?? []
        dropDiscardIfDelivered()
    }

    /// The one place a turn starts, reached only from `drain`, and now also the place a sentence
    /// goes into a turn that has already started.
    ///
    /// Answers whether the sentence actually went out, because the drain hands over more than one
    /// on a backend that takes a message mid turn and must stop at the first that did not.
    @discardableResult
    private func deliver(_ delivery: Delivery) async -> Bool {
        dispatchingDeliveryID = delivery.id
        defer { if dispatchingDeliveryID == delivery.id { dispatchingDeliveryID = nil } }
        guard !isWorkspaceArchiving else {
            await abandon(delivery, saying: "The workspace is being archived.")
            return false
        }
        // A bare `return` used to stand here, and the sentence went nowhere: `drain` has already
        // retired this delivery from the queue and drawn it as sent, so a quiet return leaves a
        // bubble claiming to have been said to an agent that was never built. It takes a database
        // that never opened, so it is close to impossible, and a message of the owner's
        // disappearing without a word is not a thing to leave resting on that.
        guard let runner = ensureRunner() else {
            await abandon(delivery, saying: "Bloom could not open an agent for this chat.")
            return false
        }
        // The queue is moving, whether or not that begins a turn.
        wasStoppedByHand = false

        // **Everything below is about a turn beginning, so it is asked whether one is.** On a
        // backend that takes a message mid turn this is reached with a turn already running, and
        // each of these lines is wrong there: the clock the footer counts from would restart in
        // the middle of the turn it is timing, the label would put "Starting" over an agent that
        // has been working for two minutes, and the roster clear would take the finished
        // subagents of the turn being read out from under the reader. See
        // `Delivery.deliverable(from:hold:on:)` for why a send arrives here at all.
        let startsATurn = !isRunning
        if startsATurn {
            activeInteractionMode = delivery.interactionMode ?? session.interactionMode
            turnStartedAt = Date()
            hasReportedTurnEnded = false
            // **The clearing rule.** The last turn's FINISHED subagents go here, at the one place
            // a turn starts, and nowhere else. Clearing them when they finish is the option that
            // reads well in a screenshot and badly in use: three rows leaving one by one take
            // everything below them up the pane while you are still reading the third. Clearing
            // them here means a finished subagent keeps its place, with its tick or its cross and
            // what it answered, for as long as the turn it belongs to is the last thing that
            // happened. One still running is not cleared at all, because it is still running. See
            // `SubagentRoster.turnStarted`.
            subagents.turnStarted()
            setRunning(true)
            statusLabel = "Starting"
            if let store, workspace != nil { await history.begin(delivery: delivery, store: store, cwd: cwd) }
            guard !wasStoppedByHand else {
                await abandon(delivery, saying: "Stopped before the message was sent.")
                if let store { await history.finish(store: store, cwd: cwd, endSeq: highestSeenMessageSeq) }
                return false
            }
        }

        do {
            // `sent` rather than `body`, and the payload beside it. They are the same string for
            // anything the owner typed and two different strings for a crew message: what the
            // model is handed is the envelope, and what the transcript draws is the words. See
            // `Delivery.sent` and `SessionRunner.send(_:recording:)`.
            try await runner.sendDelivery(delivery)
            // The runner writes the user row as part of the send, and until this line nothing read
            // it back: the transcript only pulled rows on an agent event, so the owner's own
            // message did not appear until the answer did. Reading it here is what retires the
            // echo, and `absorb` is what clears `sending` when the row lands, so the two drawings
            // of the sentence swap inside one synchronous pass and nothing on screen moves.
            await appendLatestMessages()
            return true
        } catch ProviderIdleError.retired {
            if self.runner === runner {
                pumpTask?.cancel()
                pumpTask = nil
                self.runner = nil
                runnerPreferences = nil
            }
            return await deliver(delivery)
        } catch {
            // Only what this call turned on. A send that failed into a turn somebody else started
            // must not report that turn as over: it is still running and still writing rows.
            if startsATurn {
                if let store { await history.finish(store: store, cwd: cwd, endSeq: highestSeenMessageSeq) }
                setRunning(false)
                statusLabel = nil
            }
            await abandon(delivery, saying: error.readableMessage)
            return false
        }
    }

    /// A turn that could not start, said out loud and put back in the queue.
    ///
    /// **The row is the part that was missing, and silence is what this bug cost.** An alert says
    /// it once, to whoever is looking at that moment, and then it is gone; the transcript is where
    /// somebody goes a minute later to work out what happened, and it held nothing at all. So the
    /// account of it goes in as an `.error` row, drawn by `AgentErrorRowView` beside every other
    /// way a turn can fail. A modal alert would hide that recovery UI and require dismissal before
    /// the person can act, so it is reserved for the exceptional case where no row can be stored.
    ///
    /// The delivery goes back to being pending rather than reading as sent. It used to go back
    /// into the composer, which was right when the composer was the only place an unsent prompt
    /// could live and is wrong now that there is a queue: a failed start with three messages
    /// behind it would have pasted one of them over the top of whatever the user was typing, and
    /// lost its place in the order. An unsent prompt is often minutes of thought and this app
    /// holds the only copy of it; it stays where it can be read, cancelled and sent again.
    private func abandon(_ delivery: Delivery, saying complaint: String) async {
        // Nothing was said after all, so the bubble that said it was going stops claiming so.
        sending = nil

        Log.composer.error(
            "the agent would not start, so the prompt stayed in the queue: \(complaint, privacy: .public)"
        )

        // Everything durable needs the database, and one of the two ways in here is the database
        // never having opened. Only that path needs an alert because it has nowhere to put an
        // inline explanation or a message that can be retried.
        guard let store else {
            app.alert = BloomAlert(title: "Could not start the agent", message: complaint)
            return
        }

        try? await store.releaseDeliveryClaim(id: delivery.id)
        await refreshQueue()

        let row = AgentError.notStarted(message: complaint)
        _ = try? await store.appendNext(sessionID: session.id, kind: .error, payload: row.raw)
        await appendLatestMessages()
    }

    func saveDraft() async {
        guard let store else { return }
        try? await store.saveDraft(sessionID: session.id, body: draft)
    }

    /// The one place `isRunning` moves.
    ///
    /// Seven call sites set it, and every one of them also has to reach `AppModel`, because the
    /// sidebar's status strip, Home's summary line, the menu bar item, the Dock badge and the
    /// sleep assertion are all answers to "is anything running" and none of them can see this
    /// object. `AppModel.runningWorkspaceIDs` explains why they cannot simply read it: the model
    /// dictionary those readers would have to walk is outside observation on purpose.
    ///
    /// Idempotent, so a path that stops an already stopped turn writes nothing and invalidates
    /// nobody.
    /// The turn bookkeeping `deliver` does, for a turn that arrived without one.
    ///
    /// Everything here is about the turn rather than about the message, which is why this is the
    /// part `deliver` and an `init` line have in common and the queue, the draft and the crew
    /// payload are not. Guarded by `isRunning` at the call site so a turn Bloom sent, whose `init`
    /// lands a moment after `deliver` has already done all of this, does not have its subagent
    /// rows cleared a second time.
    private func noteTheAgentStartedItsOwnTurn() {
        turnStartedAt = Date()
        // Not this turn, whatever the last one was. A Stop the owner pressed belongs to the turn
        // it stopped, and leaving it set would make the next result skip the queue drain.
        wasStoppedByHand = false
        hasReportedTurnEnded = false
        subagents.turnStarted()
        setRunning(true)
    }

    private func setRunning(_ value: Bool) {
        // A turn that has ended cannot still be waiting on a question, and there are six places
        // that end one: a stale terminal state read back from the row, a send that threw, Stop,
        // quit, the agent dying, and the result line. Clearing it here rather than at all six is
        // the same argument that made this method exist, and it happens before the guard because
        // the two flags can disagree: a turn stopped while blocked is already not running.
        if !value { setAwaitingPermission(false) }

        guard storedIsRunning != value else { return }
        storedIsRunning = value
        app.noteAgentTurnsChanged()
    }

    /// The one place `isAwaitingPermission` moves, for the same reasons `setRunning` is the one
    /// place `isRunning` does.
    ///
    /// Idempotent, so answering the second of two questions writes nothing.
    private func setAwaitingPermission(_ value: Bool) {
        guard storedIsAwaitingPermission != value else { return }
        storedIsAwaitingPermission = value
        app.noteAgentTurnsChanged()
    }

    /// Recompute from the questions actually outstanding. Called wherever one is added or settled,
    /// so a turn that asked three things goes back to running only when the last is answered.
    private func refreshAwaitingPermission() {
        setAwaitingPermission(!pendingPermissionAsks.isEmpty)
    }

    /// The UI stops looking busy right away, but the pump is deliberately left running: a cancelled
    /// turn still emits its own result, and that event is what writes the final state back into the
    /// session row. Tearing the pump down here used to strand the session until the next launch.
    func stop() {
        if let cloud {
            // The machine's queue pauses and its turn stops; what the chat shows next comes back
            // on the event stream. Nothing is handed back to the composer, because the queue may
            // hold other people's messages.
            statusLabel = nil
            Task { await cloud.stop() }
            return
        }
        steering = nil
        cancelTurn()

        // **And the queue comes back with it.** Not draining after a Stop was right about the
        // messages not going and wrong about what became of them: they sat under the transcript
        // for the rest of the launch, under a sentence that had promised they would go when this
        // turn ended. They go back to the composer instead, where they can be read, changed and
        // sent again, and where nothing is promising anything on their behalf. See
        // `PendingMessageReturn`.
        //
        // A task rather than an await, because Stop has to look instant: cancelling the turn is
        // the thing the hand asked for, and it must not wait on two round trips to a SQLite actor
        // that a diff refresh can be sitting in front of.
        Task { await returnQueueToComposer() }
    }

    /// Cancelling the running turn, and saying nothing about what happens next.
    ///
    /// The callers want opposite things from the queue, so one method meant one of them was
    /// wrong. Stop hands the waiting messages back to the composer, and Steer sends one of them
    /// in the space it just made; quitting, archiving and closing a chat have to leave the queue
    /// exactly where it is, because a queued message survives a relaunch on purpose and coming
    /// back as a draft in a chat nobody has open is not surviving. The shared half is here and
    /// each caller says what it wants after it.
    private func cancelTurn() {
        // Remembered so the result this cancellation is about to produce does not look like a turn
        // that finished, and therefore does not let the queue move. See `wasStoppedByHand`.
        wasStoppedByHand = true
        runner?.cancelNow()
        setRunning(false)
        statusLabel = nil
        clearStreaming()
    }

    /// The chat is going away for good, so the process goes with it.
    ///
    /// `stop()` above is deliberately not this. Stop leaves a Codex chat's `app-server` running,
    /// because that is what makes the next message resume in the same process with the grants the
    /// person already gave; closing, archiving and quitting mean the opposite, and used to reach
    /// the same method. So a Codex chat's server was never signalled by anything, which is the
    /// orphaned-children bug this app already fixed once on the Claude Code side.
    func terminateNow() {
        // `cancelTurn` rather than `stop`, and this is the reason the two are separate: Stop's
        // other half empties the queue into a composer that is going away with this chat.
        cancelTurn()
        // A Steer waits on the result of the turn it stopped, and nothing is coming back from a
        // process about to be signalled. The message stays queued, which is where it was.
        steering = nil
        runner?.terminateNow()
    }

    /// The session itself is going away, so the pump goes with it. The event stream never ends on
    /// its own, and a pump left iterating one holds its runner alive for the rest of the launch.
    func teardown() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        terminateNow()
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// Quit path. Signals the agent and waits, briefly, for it to actually be gone, because macOS
    /// hands our children to launchd rather than killing them.
    ///
    /// The wait is on the process, not on the turn. Polling "is a turn running" is what let this
    /// return happily on a Codex chat whose server was still very much alive: the interrupt landed,
    /// the turn closed, and nothing had ever been signalled.
    func shutdown() async {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        guard let runner else { return }
        terminateNow()

        let deadline = ContinuousClock.now.advanced(by: .seconds(3.5))
        while ContinuousClock.now < deadline {
            let alive = await runner.isProcessAlive
            if !alive { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private var isWorkspaceArchiving: Bool {
        workspace.map { app.isArchiving($0.id) } ?? false
    }

    /// Starts the runner and the event pump on first use. The pump is rebuilt whenever it is
    /// missing, so no path can leave a live runner with nothing reading its events.
    ///
    /// Which runner is the chat's own answer, read off `session.agentKind`, and it is read once:
    /// a chat that has started is on the backend it started on for as long as it lives. Changing
    /// the picker on a chat that has already spoken forks a new chat rather than turning this one
    /// into something else, because its rows, its thread and its context all belong to the backend
    /// that made them. See `ComposerBackendChange` and docs/CODEX.md.
    /// Nil when the database never opened, rather than a crash.
    ///
    /// It was `app.store!`, the one force unwrap in this file where every other reference goes
    /// through `store` and a `guard let`. It was safe only because its single caller guards four
    /// lines up, which is a fact about `deliver` rather than about this method. `app.store` stays
    /// nil forever if the open in `AppModel.bootstrap` throws while `isLoaded` is set true, so a
    /// second caller of this would take the app down. There is no reason for the guarantee to be
    /// somewhere other than here.
    private func ensureRunner() -> (any SessionRunner)? {
        guard !usesInteractiveTerminal else { return nil }
        guard !isWorkspaceArchiving else { return nil }
        guard let store else { return nil }
        let preferences = RunnerPreferences(session: session)
        if runner != nil, runnerPreferences != preferences {
            runner?.terminateNow()
            pumpTask?.cancel()
            pumpTask = nil
            runner = nil
            runnerPreferences = nil
        }
        // Registration mints a new token and revokes the previous one. Reusing a runner must
        // keep its token too, or the next bridge call closes its still-connected transport.
        if let runner {
            if pumpTask == nil { startPump(on: runner) }
            return runner
        }
        // Two registrations, because there are two identities. A chat in a worktree gets a token
        // minted for that workspace and the role its origin says; Ask Bloom gets the owner's own,
        // which is the same door the owner's terminal comes in through and the reason every owner
        // tool works here without one of them being written twice.
        let bridge = workspace.map { app.bridge?.register(session: session, workspace: $0) }
            ?? app.bridge?.register(askSession: session)
        let runner = Self.makeRunner(
            session: session,
            workspacePath: cwd,
            store: store,
            bridge: bridge
        )
        self.runner = runner
        runnerPreferences = preferences
        startIdleEviction()
        if pumpTask == nil { startPump(on: runner) }
        return runner
    }

    private var usesInteractiveTerminal: Bool {
        guard let workspaceID = session.workspaceID else { return false }
        CenterTabStore.shared.load(workspaceID: workspaceID)
        return CenterTabStore.shared.terminal(for: session.id, in: workspaceID) != nil
    }

    /// The one place a backend becomes a process. Static and taking only values, so which runner a
    /// session gets can be asserted on without a workspace, a store or a view.
    ///
    /// The bridge is per process, so it belongs wherever the process is decided. A runner built
    /// anywhere else would be a second CLI on the same session row, which is the invariant
    /// `BridgeServer` refuses to touch and the reason nothing on the bridge's side of the socket
    /// may build one.
    static func makeRunner(
        session: Session,
        workspacePath: String,
        store: Store,
        bridge: BridgeHandle? = nil
    ) -> any SessionRunner {
        switch session.agentKind {
        case .codex:
            return CodexRunner(
                workspacePath: workspacePath,
                session: session,
                store: store,
                bridge: bridge?.attachment
            )
        case .grok:
            return GrokRunner(
                workspacePath: workspacePath,
                session: session,
                store: store,
                bridge: bridge?.attachment
            )
        // Cursor and OpenCode have no runner, and `AgentKind.canRunWorkspaces` is what stops a
        // chat ever being on one. A chat that somehow is falls back to Claude Code rather than
        // refusing to start, because a transcript that cannot be typed into is a worse answer
        // than one running the backend every existing chat already runs.
        case .claudeCode, .cursor, .openCode:
            return AgentRunner(
                workspacePath: workspacePath,
                session: session,
                store: store,
                mcpConfigPath: bridge?.mcpConfigPath
            )
        }
    }

    private func startIdleEviction() {
        guard idleEvictionTask == nil else { return }
        idleEvictionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await evictIdleProvider()
            }
        }
    }

    private func evictIdleProvider() async {
        guard let store, let current = runner, !isRunning, !isAwaitingPermission,
              sending == nil, pendingDeliveries.isEmpty, !subagents.isAnythingRunning else { return }
        let stored = try? await store.setting(ProviderIdlePolicy.settingKey)
        guard let duration = ProviderIdlePolicy.duration(stored: stored),
              let waiting = try? await store.pendingDeliveries(sessionID: session.id), waiting.isEmpty,
              !isRunning, sending == nil else { return }
        guard await current.evictIfIdle(for: duration), runner === current else { return }
        pumpTask?.cancel()
        pumpTask = nil
        runner = nil
        runnerPreferences = nil
    }

    private func startPump(on runner: any SessionRunner) {
        if let feed = runner.presentationFeed {
            let baseline = feed.snapshot()
            let subscriber = UUID()
            let notifications = feed.notifications(id: subscriber, after: baseline.revision)
            pumpTask = Task { [weak self] in
                defer { feed.unsubscribe(subscriber) }
                var cursor = baseline.revision
                var pendingResult: AgentResult?
                if baseline.revision > 0, let recovery = baseline.recovery, let self {
                    await recoverPresentation(recovery, after: baseline.revision)
                    setRunning(session.state.isMidTurn)
                }
                for await _ in notifications {
                    guard let self, !Task.isCancelled else { return }
                    let batch = feed.read(after: cursor)
                    do {
                        if let failure = batch.failure { throw PresentationFailure(message: failure) }
                        let result = try await consumePresentation(batch, from: feed, after: cursor)
                        pendingResult = result ?? pendingResult
                        cursor = batch.revision
                        await feed.acknowledgePage(subscriber: subscriber, through: cursor)
                        // New lifecycle events may have arrived while checkpoints were saved.
                        // Catch up before allowing any queued message to cross a turn boundary.
                        let latest = feed.snapshot()
                        guard latest.revision == cursor else { continue }
                        if let event = latest.recovery?.stateEvent, case .error = event { pendingResult = nil }
                        if AgentPresentationReconciliation.permitsAutomaticDrain(
                            isCatchingUp: isReconcilingPresentation, isTurnRunning: isRunning || feed.isTurnRunning
                        ), let result = pendingResult {
                            pendingResult = nil
                            await finishPresentationTurn(result)
                        }
                    } catch {
                        runner.terminateNow()
                        await handle(.error(AgentError(message: error.localizedDescription)))
                        return
                    }
                }
            }
            return
        }
        pumpTask = Task { [weak self] in
            for await event in runner.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private struct PresentationFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func consumePresentation(
        _ batch: AgentPresentationBatch, from feed: AgentPresentationFeed, after cursor: UInt64
    ) async throws -> AgentResult? {
        isReconcilingPresentation = true
        defer {
            isReconcilingPresentation = false
            isReplayingPastTurn = false
            presentationMessageSeq = nil
        }
        var result: AgentResult?
        if let recovery = batch.recovery {
            var lifecycleCursor = cursor
            while true {
                let page = try await feed.lifecyclePage(after: lifecycleCursor, through: batch.revision)
                guard !page.isEmpty else { break }
                for entry in page {
                    isReplayingPastTurn = feed.hasLaterTurn(than: entry.revision)
                    presentationMessageSeq = entry.messageSeq
                    await handle(entry.event)
                    if case .result(let terminal) = entry.event { result = terminal }
                    lifecycleCursor = entry.revision
                }
            }
            // Boundaries were replayed independently; never apply the latest boundary twice.
            await recoverPresentation(recovery, after: batch.revision)
        } else {
            for index in batch.events.indices {
                isReplayingPastTurn = feed.hasLaterTurn(than: batch.eventRevisions[index])
                presentationMessageSeq = batch.messageSequences[index]
                let event = batch.events[index]
                await handle(event)
                if case .result(let terminal) = event { result = terminal }
            }
        }
        return result
    }

    private func finishPresentationTurn(_ result: AgentResult) async {
        if let steered = steering {
            steering = nil
            wasStoppedByHand = false
            await sendSteered(steered)
        } else if !wasStoppedByHand { await drain() }
        if !isRunning {
            await reportToOrchestrator(CrewMessage.stopped(name: session.title, lastMessage: result.summary))
            await app.noteWorkspaceTurnEnded(
                WorkspaceTurnEnding.ofResult(result, stoppedByOwner: wasStoppedByHand), in: session
            )
        }
    }

    private func recoverPresentation(_ recovery: AgentPresentationRecovery, after cursor: UInt64) async {
        // Rows and permission decisions are durable. Reload those first; the current live tail
        // is a snapshot, so assigning it never loses or repeats individual text chunks.
        await appendLatestMessages()
        await refreshSession()
        if let store {
            let decisions = (try? await store.permissionAskDecisions(sessionID: session.id)) ?? [:]
            for (id, decision) in decisions {
                settle(PermissionResolution(requestID: id, decision: decision))
            }
        }
        refreshAwaitingPermission()
        subagents = recovery.subagents
        if recovery.stateRevision > cursor, let event = recovery.stateEvent {
            await handle(event)
        }
        clearStreaming()
        streamingText = recovery.text
        streamingThinking = recovery.thinking
        streamingToolName = recovery.toolName
        thinkingTokens = recovery.thinkingTokens
        if let status = recovery.status { await handle(.status(status)) }
        if let retry = recovery.retry { absorb(retry) }
        if let quota = recovery.quota { await app.recordQuotas(AgentQuotaAdapters.quotas(fromRateLimitEvent: quota)) }
        if isAwaitingPermission { statusLabel = "Waiting on you" }
    }

    // MARK: - Event handling

    /// The event pump's door, opened for one caller: `StreamProbe`.
    ///
    /// **A probe hook in a production type, deliberately, and this is the argument for it.** What
    /// the probe has to measure is what Bloom does with a delta, and the only faithful way to
    /// measure that is to hand this the events a runner hands it. The alternative was a probe that
    /// wrote `streamingText` directly, which measures a property being assigned rather than a turn
    /// arriving, and would go on measuring it after the pump around it had changed. Nothing else
    /// may call this: a runner reaches `handle` through its own pump, and anything else pushing
    /// events into a transcript would be a second writer on state that has exactly one.
    func acceptForProbe(_ event: AgentEvent) async {
        await handle(event)
    }

    private func handle(_ event: AgentEvent) async {
        switch event {
        case .initialized:
            // **A turn Bloom did not send starts here and nowhere else.** The CLI runs a
            // background task's completion notification as a turn of its own, and it announces
            // each one with an `init` exactly as it announces the ones Bloom asks for. Until this
            // line the pane learned a turn had begun only from `deliver`, so a chat working its
            // way through five self-started turns drew no activity mark on its tab, no busy
            // sidebar row, and a Send button in place of Stop. `AgentRunner.ingest` moves the
            // stored state on the same event, for the same reason and with the same argument.
            if !isRunning { noteTheAgentStartedItsOwnTurn() }
            // The runner persists the agent session id itself. Read it back rather than writing
            // our own copy, which would be a second writer racing the runner on the same row.
            await refreshSession()
            statusLabel = "Working"

        case .status(let label):
            // "Requesting" describes the CLI's protocol state, not what the person is waiting
            // for. The model has the request at this point and has not started answering yet.
            statusLabel = label.lowercased() == "requesting"
                ? "Waiting for model"
                : label.capitalizedFirst

        case .retrying(let retry):
            absorb(retry)

        case .thinkingTokens(let total):
            thinkingTokens = total

        case .streamDelta(let delta):
            switch delta {
            case .text(let chunk): buffer.text += chunk
            case .thinking(let chunk): buffer.thinking += chunk
            // Not buffered. It arrives once per tool call rather than per token, and it is what
            // the status line under the tail says, so a delay on it would be visible where a
            // delay on a few characters of prose is not.
            case .toolName(let name): streamingToolName = name
            case .toolInput: break
            case .blockFinished: break
            }
            scheduleStreamFlush()

        case .assistantText, .thinking, .toolUse, .toolResult:
            // Anything at all arriving from the model means the request that was being retried got
            // through. That is the only signal there is: the CLI announces a retry and never
            // announces a recovery, so the recovery is the next event of any kind.
            settleRetryRun()
            let runningTool = streamingToolName
            let callsBefore = freshCalls
            await appendLatestMessages()
            // Keep the live drawing while the store is awaited. Clearing first leaves an empty
            // frame between the stream and its saved row, interrupting the shared arrival.
            clearStreaming()
            // A call that just arrived is folded out of sight for a moment, so the tail goes on
            // naming it rather than saying the model is being waited on while a tool runs. Its
            // result clears this like any other arrival. See `TranscriptFold.freshCall`.
            if case .toolUse = event, !freshCalls.isSubset(of: callsBefore) {
                streamingToolName = runningTool
            }

        case .error(let failure):
            history.isFinalisingTurn = true
            // The agent died without ever producing a result: a model it does not know, expired
            // credentials, a crash. Nothing else will arrive, so the turn ends here or the composer
            // stays locked for the rest of the launch.
            //
            // The waiting row goes without leaving a note. The error row about to be drawn is
            // already the account of this outage, and two surfaces explaining one failure is
            // exactly the clutter the waiting row was written to avoid.
            //
            // A Steer booked against the turn that has just died goes with it, or it waits for a
            // result that is never coming. The message it picked stays queued, where it can be
            // pressed again once there is an agent to interrupt.
            steering = nil
            abandonRetryRun()
            clearStreaming()
            await appendLatestMessages()
            if let store { await history.finish(store: store, cwd: cwd, endSeq: presentationMessageSeq ?? highestSeenMessageSeq, captureFiles: !isReplayingPastTurn) }
            setRunning(false)
            statusLabel = nil
            // The process is gone, so every subagent under it went with it and nothing is left to
            // report their endings. This is the case `agentExited` is named for.
            subagents.agentExited()
            await refreshSession()
            app.alert = BloomAlert(
                title: "The agent stopped in \(workspaceNow?.name ?? AskConversation.title)",
                message: failure.message.isEmpty ? "It exited without finishing the turn." : failure.message
            )
            // The banner names a workspace and a chat with none has nothing to name. The alert
            // above is already on screen in front of the person who asked, which is where they
            // were: this chat is the one they opened rather than one running in the background.
            if let workspaceNow {
                NotificationService.shared.agentFailed(workspace: workspaceNow, message: failure.message)
            }
            // Both endings report, and this is the one that would otherwise be silent: an
            // orchestrator waiting on a crew member that died looks exactly like one waiting on a
            // crew member that is still thinking. See `Crew.failedSentence`.
            await reportToOrchestrator(
                CrewMessage.failed(name: session.title, reason: failure.message)
            )
            await app.noteWorkspaceTurnEnded(.failed(reason: failure.message), in: session)
            // An agent that died is an agent whose turn has ended, so a workspace it had asked to
            // archive is due now. `notifyFinished` is not on this path and never was: it is about
            // a result, and there is none. The recheck decides as it does everywhere else.
            if let workspaceNow {
                await app.archiveIfRequested(
                    workspaceNow, endedIn: session.id, wasStopped: wasStoppedByHand
                )
            }

            history.isFinalisingTurn = false

        case .result(let result):
            history.isFinalisingTurn = true
            // A turn that recovered leaves its sentence on the row that closes it; one that failed
            // leaves nothing, for the same reason as `.error` above.
            if result.succeeded { settleRetryRun() } else { abandonRetryRun() }
            clearStreaming()
            await appendLatestMessages()
            // After the append, deliberately: the row the sentence hangs under is the result row,
            // and it is not in `rows` until the read above has brought it back from the store.
            fileRecoveredRun()
            if let store { await history.finish(store: store, cwd: cwd, endSeq: presentationMessageSeq ?? highestSeenMessageSeq, captureFiles: !isReplayingPastTurn) }
            setRunning(false)
            statusLabel = nil
            // **A result is not news about a subagent, and assuming it was is what hid them.**
            // `claude` runs for the whole session and the next turn is written into the same
            // process, so an `Agent` call that answered "the agent is working in the background"
            // is still working after this line and still going to report its own ending here.
            // Marking everything stopped took its row away seconds after it was spawned, and the
            // clear at the next turn's start then made sure it never came back: a workspace with
            // a spinner and no children under it while two agents were six minutes in.
            //
            // A turn the owner stopped is the other case, and there the process really was
            // signalled, so the children genuinely died with it.
            if wasStoppedByHand { subagents.agentExited() }
            // Token counts, cost and state are all written by the runner as part of handling the
            // same result. Reading them back keeps one writer and avoids double counting.
            await refreshSession()
            await notifyFinished(result: result)
            // A turn that ended by itself is the moment the next queued message is due. A turn the
            // owner stopped is not: they stepped in, and a message they queued minutes ago going
            // out into the silence they just made is the opposite of what Stop is for. Unless the
            // silence was made for one particular message, which is what Steer is: the turn was
            // stopped in order to say this, so this is what goes, and the rest of the queue waits
            // as it was. Stop's own answer is not here at all, because it has already run: the
            // queue was handed back to the composer on the frame the button was pressed.
            history.isFinalisingTurn = false
            if !isReconcilingPresentation, let steered = steering {
                steering = nil
                wasStoppedByHand = false
                await sendSteered(steered)
            } else if !isReconcilingPresentation, !wasStoppedByHand {
                await drain()
            }
            // After the drain, and only if nothing moved: a crew member whose orchestrator said
            // something while it was busy has just started the next turn, and telling the
            // orchestrator it has stopped in the same breath would have it act on an answer that
            // is about to be superseded. `drain` is awaited to completion above, `runner.send` and
            // all, and `deliver` sets `isRunning` before that send, so by this line the flag is
            // already describing the turn that has just begun rather than the one that ended.
            if !isReconcilingPresentation, !isRunning {
                await reportToOrchestrator(
                    CrewMessage.stopped(name: session.title, lastMessage: result.summary)
                )
                // The same moment, one workspace further out: a chat elsewhere that asked
                // `workspace_say` or `workspace_start` to tell it when this came to rest.
                await app.noteWorkspaceTurnEnded(
                    WorkspaceTurnEnding.ofResult(result, stoppedByOwner: wasStoppedByHand), in: session
                )
            }

        case .permissionAsk:
            // The row goes in where the call would have been, and the composer stops looking like
            // an agent that is working: it is alive, and it is not going anywhere.
            clearStreaming()
            await appendLatestMessages()
            statusLabel = "Waiting on you"
            refreshAwaitingPermission()
            await refreshSession()
            if let workspaceNow {
                NotificationService.shared.agentNeedsPermission(workspace: workspaceNow)
            }
            // A turn stuck on the owner looks, from another workspace, exactly like one still
            // working. Not while replaying: an ask read back after a relaunch may have been
            // answered long ago, and the watch is spent by whatever it says.
            if !isReconcilingPresentation, !isReplayingPastTurn, let ask = pendingPermissionAsks.last {
                await app.noteWorkspaceTurnEnded(WorkspaceTurnEnding.ofAsk(ask), in: session)
            }

        case .permissionDecided(let resolution):
            settle(resolution)
            refreshAwaitingPermission()
            if !isAwaitingPermission {
                statusLabel = isRunning ? "Working" : nil
            }
            await refreshSession()

        case .rateLimit(let raw):
            // Both backends converge on this one event, and until now it landed here and stopped.
            // The adapters recognise their own payload and decline the rest, so this one line
            // serves every backend that publishes an allowance and every backend that does not.
            await app.recordQuotas(AgentQuotaAdapters.quotas(fromRateLimitEvent: raw))

        case .subagent(let signal):
            subagents.apply(signal)
            // Between turns the runner has just stored this as the line opening the turn the CLI
            // is about to start, and nothing else would read it in until that turn's first row
            // arrived. See `BackgroundWake`.
            if case .reported = signal, !isRunning { await appendLatestMessages() }

        case .contextCompacted:
            // **Read in now rather than on the next row.** The runner has already stored the
            // boundary, and the next thing that would bring it in is the model's answer, which is
            // a whole request away: the line saying what happened would appear a minute after it
            // happened. Same argument, and the same one line, as the background wake above.
            await appendLatestMessages()
            // The word in the status row is stale the moment the boundary lands. The CLI does
            // send `requesting` next, but not immediately, and "Compacting" left standing after
            // the compaction has finished is the row lying about what it is waiting for.
            if isRunning, ContextCompaction.isCompacting(status: statusLabel ?? "") {
                statusLabel = "Working"
            }

        case .hook, .unknown:
            break
        }
    }

    // MARK: - Retries

    /// Folds one announcement into the run it belongs to, starting one if this is the first.
    ///
    /// Only the turn's own retries reach here. A subagent's arrive on its `tool_progress` line,
    /// which is a `.subagent` event, and they live on that subagent's row in `subagents`: they are
    /// a different request with a different backoff, and folding them in here would have the
    /// turn's row counting somebody else's attempts.
    private func absorb(_ retry: AgentRetry) {
        if retryRun != nil {
            retryRun?.absorb(retry)
        } else {
            retryRun = RetryRun(retry)
        }
    }

    /// The wait ended and the work carried on. The run stops being live and is held until the turn
    /// closes, because the row its sentence hangs under is the result row and that does not exist
    /// yet.
    ///
    /// The first run of a turn is the one kept. A turn that hit the outage early, recovered, and
    /// hit it again later is one story about one evening, and the first attempt count is the one
    /// that explains the minutes.
    private func settleRetryRun() {
        guard let run = retryRun else { return }
        if settledRun == nil { settledRun = run }
        retryRun = nil
    }

    /// Files a settled run under the row that closed the turn, once that row is in `rows`.
    private func fileRecoveredRun() {
        guard let run = settledRun, let seq = rows.last?.seq else { return }
        recoveredRuns[seq] = run
        settledRun = nil
    }

    /// A run that has ended in success but whose turn has not closed yet, so the sentence has a
    /// row to hang under when it does.
    private var settledRun: RetryRun?

    /// The turn failed. The run is dropped whole: nothing is said about the waiting, because the
    /// failure is about to say it.
    private func abandonRetryRun() {
        retryRun = nil
        settledRun = nil
    }

    // MARK: - Permission asks

    /// What the project is called, for a permission row that has to say where a rule would apply.
    /// "Always allow ... in Bloom" is a promise about a place, and the place has to be named.
    /// Nil when there is no project behind this chat, which is what stops the card offering a
    /// scope it cannot store. See `PermissionScopeOffer`.
    var projectName: String? {
        guard let workspace else { return nil }
        return app.repo(for: workspace)?.name ?? workspaceNow?.name
    }

    /// The questions this session is holding a turn open for, in the order they arrived.
    var pendingPermissionAsks: [PermissionAsk] {
        rows.compactMap { row in
            guard row.kind == .permissionAsk, row.permissionDecision == nil else { return nil }
            return PermissionAsk.decode(payload: row.payload)
        }
    }

    /// Answer one question. The turn resumes on the other side of this.
    ///
    /// The row is settled here rather than waiting for the event to come back round, so the
    /// buttons stop being pressable the moment one of them is, and a slow store cannot leave two
    /// answers on their way to the same question.
    func answer(requestID: String, decision: PermissionDecision) async {
        if let cloud {
            await answerOnCloud(requestID: requestID, decision: decision, through: cloud)
            return
        }
        if case .approvePlan = decision {
            // Saving the implementation mode can fail. Keep the card answerable until the
            // runner confirms it, rather than showing a settled plan above a blocked agent.
            await runner?.answer(requestID: requestID, decision: decision)
            return
        }
        settle(PermissionResolution(requestID: requestID, decision: decision.storedName))
        refreshAwaitingPermission()
        await runner?.answer(requestID: requestID, decision: decision)
    }

    /// Mark a question answered on the row that asked it.
    private func settle(_ resolution: PermissionResolution) {
        guard let index = rows.firstIndex(where: {
            $0.kind == .permissionAsk
                && PermissionAsk.decode(payload: $0.payload)?.requestID == resolution.requestID
        }) else { return }

        foldCache.invalidate(row: index)
        rows[index].permissionDecision = resolution.decision
        if !resolution.note.isEmpty { rows[index].permissionNote = resolution.note }
        presentationRevision += 1
    }

    /// Pulls anything the runner has persisted since the last row we hold. The runner is the
    /// single writer, so reading back from the store keeps one ordering and one source of truth.
    private func appendLatestMessages() async {
        guard let store else { return }
        // Nothing is appended to a list the first read is still building. A workspace can be handed
        // a prompt the same moment its model is made, which starts the agent while the history is
        // still on its way in, and the read ends by putting the whole list on the model in one go:
        // a row appended here in the meantime would simply be overwritten.
        await loader.wait()
        let fresh = (
            try? await store.messages(sessionID: session.id, afterSeq: highestSeenMessageSeq)
        ) ?? []
        guard !fresh.isEmpty else { return }
        let appendedFrom = rows.count
        var calls: [String] = []
        // **Filtered against the cursor again, having already been queried against it.** The read
        // above is a suspension point, so two calls can both ask for everything after `n` and both
        // come back with the same rows: the cursor only moves in the loop below, which neither of
        // them has reached. Appending twice would put two rows carrying one id under a `ForEach`,
        // which is the shape SwiftUI answers by drawing one of them and losing the other.
        //
        // The pump is serial, so two event handlers cannot be the pair. What can is the pump and a
        // `drain` the reader started, and that window is narrow rather than closed. A comparison
        // per row is cheaper than the reasoning needed to prove it never happens.
        for message in fresh where message.seq > highestSeenMessageSeq {
            // Before folding, because a tool result changes an old row rather than appending one.
            // The cursor belongs to stored messages, not to their presentation.
            highestSeenMessageSeq = max(highestSeenMessageSeq, message.seq)
            if message.kind == .toolUse, let id = message.refID { calls.append(id) }
            absorb(message)
        }
        // A question stops the turn on a person, and a running call drawn in above it a moment
        // later would move the buttons they are reaching for. So it is drawn now, with the question.
        if fresh.contains(where: { $0.kind == .permissionAsk }) {
            endFreshCalls(Array(freshCalls))
        } else if !calls.isEmpty {
            beginFreshCalls(calls)
        }
        // Over what actually arrived, not over the transcript. A tool result folds onto a row that
        // is already there rather than appending, so the slice can be empty, and an empty one
        // leaves the held reading exactly where it was.
        noteContextWindow(in: rows[min(appendedFrom, rows.count)...])
    }

    /// Lets calls that have just arrived fold straight away, and draws any still running once
    /// `TranscriptFold.freshCall` has passed.
    ///
    /// **A timer rather than waiting for the result, because a call can run for minutes.** Held out
    /// of sight until its result, a test run would be a count and a status line and nothing else.
    private func beginFreshCalls(_ calls: [String]) {
        freshCalls.formUnion(calls)
        Task { [weak self] in
            try? await Task.sleep(for: TranscriptFold.freshCall)
            self?.endFreshCalls(calls)
        }
    }

    private func endFreshCalls(_ calls: [String]) {
        var revealed = false
        for id in calls where freshCalls.remove(id) != nil {
            // A call that settled while fresh folds either way, so only a running one changes what
            // the fold says.
            guard let index = indexByRefID[id], rows.indices.contains(index),
                  rows[index].resultPayload == nil else { continue }
            foldCache.invalidate(row: index)
            revealed = true
        }
        if revealed { presentationRevision += 1 }
    }

    /// Folds what the newest rows say about the context window into the held reading.
    private func noteContextWindow(in appended: ArraySlice<TranscriptRow>) {
        let usage = ContextWindowUsage.updated(contextUsage, with: appended)
        if usage != contextUsage { contextUsage = usage }
    }

    /// Text and thinking that has arrived and is not on screen yet. See `scheduleStreamFlush`.
    ///
    /// **`@ObservationIgnored`, and it is the difference between a redraw costing one pass over
    /// the transcript and a token costing one.** This is staging. It is written on every delta,
    /// which is tens to hundreds of times a second, and nothing outside `flushStream` has any
    /// business reading it. Observed, it was an edge that anything reading `isStreaming` took, and
    /// `TranscriptListView` was one of those: on the owner's 2,981 row session every single token
    /// walked the whole list's dependencies to find that nothing it draws had moved, and then the
    /// same again fifty milliseconds later when the flush it was staging for actually happened.
    @ObservationIgnored private var buffer = (text: "", thinking: "")
    private var streamFlush: Task<Void, Never>?

    /// How often the live tail is allowed to redraw while an answer arrives.
    ///
    /// **Fifty milliseconds, because the cost of drawing the tail is per REDRAW and the rate the
    /// deltas arrive at is not ours to choose.** Measured with `--stream-probe` on a release
    /// build over a 1,582 row chat: 6.6ms of main thread per delta at sixty deltas a second, which
    /// is 40% of a core burned continuously for as long as an agent is writing, and thirty per
    /// cent of frames late. Most of that is the same work over and over: the whole answer so far
    /// is re-parsed as markdown and re-measured by TextKit on every delta, so a turn that streams
    /// n chunks does O(n²) work to draw one paragraph.
    ///
    /// Coalescing bounds it. Twenty redraws a second is faster than anybody reads and is the same
    /// number whether the backend sends twenty five chunks a second or two hundred, which is the
    /// property that matters: what the app costs while a turn runs stops depending on how chatty
    /// the CLI happens to be.
    ///
    /// Nothing is lost by waiting. Every path that ENDS a stream flushes first, so the last few
    /// characters are on screen before the stored row replaces them.
    private static let streamFlushInterval = Duration.milliseconds(50)

    private func scheduleStreamFlush() {
        guard streamFlush == nil else { return }
        streamFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.streamFlushInterval)
            guard let self else { return }
            streamFlush = nil
            flushStream()
        }
    }

    /// Puts what has arrived on screen, in one write per property rather than one per delta.
    private func flushStream() {
        if !buffer.text.isEmpty {
            if streamingText.isEmpty { messageArrivals.beganStream(.assistantText) }
            streamingText += buffer.text
            buffer.text = ""
        }
        if !buffer.thinking.isEmpty {
            if streamingThinking.isEmpty { messageArrivals.beganStream(.thinking) }
            streamingThinking += buffer.thinking
            buffer.thinking = ""
        }
    }

    private func clearStreaming() {
        streamFlush?.cancel()
        streamFlush = nil
        buffer = ("", "")
        streamingText = ""
        streamingThinking = ""
        streamingToolName = nil
    }

    /// Whether an answer is arriving, as far as anything that draws is concerned.
    ///
    /// **Deliberately blind to `buffer`.** The staging is `@ObservationIgnored`, so a term reading
    /// it would be a term nothing is told about, and this would go stale rather than late. Over
    /// the flushed properties alone it moves at `streamFlushInterval` instead of per token, which
    /// is the whole of what a reader of this wants: twenty answers a second about something that
    /// is only redrawn twenty times a second.
    ///
    /// Nothing appears late because of it. The live tail is drawn on `isRunning || isStreaming`,
    /// and `isRunning` is written synchronously by `deliver` before the send is even awaited, so
    /// the tail is on screen from the frame the turn begins whatever this says. See
    /// `StreamingTailView`.
    var isStreaming: Bool {
        !streamingText.isEmpty || !streamingThinking.isEmpty || streamingToolName != nil
    }

    /// Tells the chat that started this one that it has stopped, and lets that chat's queue move.
    ///
    /// **This is the whole point of the crew design, which is why it hangs off the end of a turn
    /// rather than off a tool an orchestrator has to remember to call.** An orchestrator that has
    /// to ask either polls or forgets, so the end of a crew member's turn is an event Bloom
    /// delivers, carrying what the agent last said rather than a handle to go and fetch it. The
    /// head of `Crew` argues it at length, and the two sentences are written there so that the
    /// promise is one a test can read.
    ///
    /// It enqueues and only then drains, rather than sending. The orchestrator is very often mid
    /// turn at this moment, because a turn of its own is usually what started this agent, and
    /// `DeliveryHold` is what decides. On a backend that takes a message mid turn the report goes
    /// into that turn, which is what the orchestrator wanted anyway; on one that does not it goes
    /// when the turn ends. Either way it is the same `drain` every other queued message goes
    /// through, and it keeps its place in the same order.
    ///
    /// A chat nobody started returns on the first line, which is nearly every chat in the app.
    ///
    /// At most one report per turn, whichever ending gets here first. See `hasReportedTurnEnded`.
    ///
    /// A `CrewMessage` rather than a sentence, because the two readers want different lengths of
    /// it: the orchestrator is handed the paragraph with the agent's last words and the hint about
    /// tidying up, and the owner's window draws the one line saying the agent stopped. Handing one
    /// string to both is what put an instruction addressed to a model in the owner's own bubble.
    private func reportToOrchestrator(_ message: CrewMessage) async {
        guard let parentID = session.parentSessionID, let store, let workspace else { return }
        guard !hasReportedTurnEnded else { return }
        // **Claimed here rather than after the read below, and the difference is the promise this
        // method makes.** The doc says at most one report per turn, whichever ending gets here
        // first, and with the flag set after the `await` that held only because the event pump is
        // serial: two callers arriving together would both pass the guard, both wait on the store,
        // and both enqueue, telling an orchestrator twice that one agent stopped. `Crew`'s own
        // head says what that costs, which is an orchestrator picking the work back up twice.
        //
        // Claiming before the suspension costs nothing on the path that goes on to return: the
        // three guards above have already established that there is a parent to report to, and a
        // report abandoned because that parent turned out to be closed is a report that must not
        // be tried again anyway.
        hasReportedTurnEnded = true

        // Read before the enqueue, and dropped when the chat above has been closed. `session(id:)`
        // answers for an archived row where `sessions(workspaceID:)` and `crew(of:)` do not, and
        // `closeSession` archives a chat while leaving the crew it started running. A report
        // enqueued against a closed chat did not sit there quietly: the drain below built that
        // session a fresh transcript, minted it a bridge token and started a turn in a
        // conversation that is in no tab strip, no session list and no sidebar row. An agent
        // nobody can see, spending money.
        guard let parent = try? await store.session(id: parentID),
              parent.archivedAt == nil else { return }

        _ = try? await store.enqueueDelivery(
            Delivery(
                targetSessionID: parentID,
                sourceWorkspaceID: workspace.id,
                kind: .report,
                crew: message
            )
        )

        // `existingModel` rather than `model(for:)`: `workspace` here is the snapshot this model
        // was made with, and handing a stale one to `model(for:)` pushes it back into the live
        // model, which is the bug `notifyFinished` below is written around. A crew member's
        // orchestrator is in this same worktree, so the model it needs is one that already exists.
        guard let model = app.existingModel(for: workspace.id) else { return }
        let transcript = model.transcript(for: parent)
        await transcript.refreshQueue()
        await transcript.drain()
    }

    private func notifyFinished(result: AgentResult) async {
        guard let store else { return }
        // Every line below is about a worktree: an unread mark on a sidebar row, a workspace model
        // to refresh, a banner naming where the turn finished. A chat with none is a chat the
        // owner is looking at, so there is nothing to mark and nobody to tell.
        guard let workspace, let workspaceNow else { return }
        try? await store.touch(
            workspaceID: workspace.id, unread: app.selection.workspaceID != workspace.id
        )

        // `workspaceNow`, twice over: `model(for:)` pushes the value it is handed into the
        // live model, so the stale snapshot did not just misname the notification, it reverted
        // the model's row in memory (name, colour, unread) until the change feed repaired it.
        let model = app.model(for: workspaceNow)
        await model.onTurnFinished()

        NotificationService.shared.turnFinished(
            workspace: workspaceNow, result: result, wasCancelled: session.state == .cancelled
        )

        // Last, and after the banner, because this is the one thing here that can take the
        // workspace away: a notification about a turn that finished in a workspace is worth
        // sending whether or not the worktree survives the next line.
        //
        // Before the drain rather than after it, which is the ordering that matters. `drain` runs
        // once this returns and is guarded by `isWorkspaceArchiving`, so an archive that starts
        // here cannot have a queued message sent into it; and a workspace that still has one
        // queued is refused with the true reason rather than with "an agent is running" a
        // fraction of a second later.
        //
        // `wasStoppedByHand` is read here rather than a few lines down for the reason the drain
        // reads it: the owner stepped in, and a worktree removing itself out from under somebody
        // who has just pressed Stop is the opposite of what Stop is for. It is still true at this
        // line for a Steer, which is a stop made in order to say one particular thing, and that is
        // right too. See `AppModel.archiveIfRequested`.
        await app.archiveIfRequested(
            workspaceNow, endedIn: session.id, wasStopped: wasStoppedByHand
        )
    }

    // MARK: - Cloud

    /// Why the machine's queue for this chat is paused, when it is. See `holdSentence`.
    private(set) var cloudQueueError: String?
    /// How many machine rows the list above was built from, so a page that arrives after its
    /// events (and lands in the middle) is told apart from rows arriving at the end.
    @ObservationIgnored private var cloudRowCount = 0
    @ObservationIgnored private var cloudChatRecord: ChatRecord?
    @ObservationIgnored private var cloudPendingQuestions: Set<String>?

    /// Folds what the machine says about this chat into the model the transcript and the composer
    /// draw: its rows, its streaming text, whether a turn is running, its questions and its queue.
    ///
    /// Rows arriving at the end are absorbed one by one, as a local turn's are. Anything else (a
    /// history page landing under rows the stream already delivered) rebuilds the list, which is
    /// the one read `read(from:)` would have done; it happens once per page, not per event.
    func receiveCloud(_ chat: CloudChatState, streaming: String, workspaceID: CloudWorkspaceID, readerID: String?) {
        guard cloud != nil else { return }
        if let record = chat.chat, record != cloudChatRecord {
            cloudChatRecord = record
            var fresh = Session(cloudChat: record)
            fresh.lastReadSeq = session.lastReadSeq
            if fresh != session { session = fresh }
        }

        let pending = Set(chat.questions.map(\.requestID))
        let messages = chat.messages
        func converted(_ record: MessageRecord) -> Message {
            var message = Message(cloudMessage: record, id: CloudMessageIdentity.id(workspace: workspaceID, cursor: record.cursor))
            // The reader's own messages are drawn as theirs, without a name on them.
            if message.author?.userID == readerID { message.author = nil }
            return message
        }
        // Rows only ever arrive at the end, unless a history page landed under rows the stream had
        // already delivered. The row at the old count still being the newest one held says which,
        // without walking the chat.
        let appendsOnly = messages.count >= cloudRowCount
            && (cloudRowCount == 0 ? highestSeenMessageSeq == -1 : messages[cloudRowCount - 1].seq == highestSeenMessageSeq)
        let appended = messages.count != cloudRowCount
        if appendsOnly {
            for record in messages.dropFirst(cloudRowCount) {
                absorb(converted(record))
                highestSeenMessageSeq = max(highestSeenMessageSeq, record.seq)
            }
        } else {
            var built: [TranscriptRow] = []
            var index: [String: Int] = [:]
            for record in messages {
                Self.absorb(converted(record), decisions: [:], into: &built, indexByRefID: &index)
            }
            foldCache.reset()
            questionIndex = PinnedQuestionIndex()
            rows = built
            indexByRefID = index
            highestSeenMessageSeq = messages.last?.seq ?? -1
            presentationRevision += 1
        }
        cloudRowCount = messages.count

        // A question nobody is waiting on any more was answered, by this reader or somebody else.
        // The reader's own answer is already on the row in their words; anybody else's reads as
        // answered.
        if appended || pending != cloudPendingQuestions {
            cloudPendingQuestions = pending
            for position in rows.indices where rows[position].kind == .permissionAsk && rows[position].permissionDecision == nil {
                guard let ask = PermissionAsk.decode(payload: rows[position].payload), !pending.contains(ask.requestID) else { continue }
                foldCache.invalidate(row: position)
                rows[position].permissionDecision = PermissionDecision.answer(input: .null).storedName
                presentationRevision += 1
            }
        }

        receiveCloudStreaming(streaming)
        setRunning(chat.isRunning)
        setAwaitingPermission(!chat.questions.isEmpty)
        if !chat.isRunning, statusLabel != nil { statusLabel = nil }

        let queue = chat.queue.prompts.map { prompt in
            var delivery = Delivery(cloudPrompt: prompt, chatID: chat.id)
            if delivery.author?.userID == readerID { delivery.author = nil }
            return delivery
        }
        if queue != pendingDeliveries { pendingDeliveries = queue }
        if cloudQueueError != chat.queue.error { cloudQueueError = chat.queue.error }
        if let echo = sending, queue.contains(where: { $0.body == echo.body }) || rows.last?.kind == .user {
            // The machine has it now, as a queued prompt or as a row, so the echo retires.
            sending = nil
        }
    }

    /// Streaming text for a Cloud chat, on its own, because it arrives a few tokens at a time and
    /// nothing else about the chat moves with it.
    func receiveCloudStreaming(_ text: String) {
        if streamingText != text { streamingText = text }
    }

    /// `submit`, for a chat whose queue is on its machine.
    private func submitToCloud(
        _ text: String, through cloud: CloudChatLink, sourceDraft: String?, uploadingFiles: Bool = true
    ) async -> Bool {
        guard !text.isEmpty else { return false }
        let submittedDraft = SubmittedDraft.matching(current: draft, message: text, source: sourceDraft)
        if submittedDraft != nil { draft = "" }

        // The files go before the words do, because the words name where the files will be. A
        // refusal puts the draft back exactly as a refused send does, which is the one behaviour
        // this must share with the send below: somebody who attached a screenshot and got an
        // apology has lost nothing but the press.
        let body: String
        switch uploadingFiles ? await uploading(text, through: cloud) : .sent(text) {
        case .sent(let rewritten):
            body = rewritten
        case .refused(let title, let sentence):
            draft = PendingMessageReturn.draft(taking: [Delivery(targetSessionID: session.id, body: text)], into: draft)
            composerFocusRequests += 1
            app.alert = BloomAlert(title: title, message: sentence)
            return false
        }

        let delivery = Delivery(targetSessionID: session.id, body: body)
        messageArrivals.sent(delivery.id)
        // The echo only when nothing is ahead of it, which is when the machine will start it at
        // once; otherwise the queue event that follows draws it where it waits.
        if !queuesNextMessage { sending = delivery }
        jumpToLiveEnd()
        let outcome = await cloud.send(body)
        guard let sentence = outcome.sentence else { return true }
        // The echo goes either way: it said the turn had started, and for the unknown case that
        // is exactly what nobody can promise. What the machine really did is in the transcript,
        // which is why the sentence sends the reader there.
        if sending?.id == delivery.id { sending = nil }
        // The words come back to the composer in both cases, because losing them is worse than
        // either answer. What differs is what the person is told: see `CloudSendOutcome`.
        draft = PendingMessageReturn.draft(taking: [delivery], into: draft)
        composerFocusRequests += 1
        app.alert = BloomAlert(title: outcome.title, message: sentence)
        return false
    }

    /// What became of a Cloud turn's files.
    enum CloudUpload {
        /// The turn, with every file named where the machine put it.
        case sent(String)
        /// Nothing went. The reason, in the machine's words where it has any.
        case refused(title: String, sentence: String)
    }

    /// Puts every file this turn names on the machine, and answers the turn with their new paths.
    ///
    /// **Read out of the text rather than out of the store**, which is what makes this work for a
    /// turn composed anywhere: a message typed in the box, a quick prompt fired into it, a review
    /// with comments. A path under `.bloom/attachments` is recognisable as Bloom's own copy from
    /// the text alone, which is the property `AttachmentDraft` was built on, so the sentence is
    /// the whole record of what this turn carries.
    ///
    /// **A file that cannot go stops the turn.** The local rule is the opposite, and rightly so:
    /// there a path that no longer resolves is taken out of the sentence, because the file was
    /// deleted by somebody and the words are still worth sending. Here the file is the point.
    /// Somebody who drags a screenshot in and presses Return is asking about the screenshot, and a
    /// turn that arrives without it spends a real one on the machine answering the wrong question.
    /// So the words come back to the composer with the reason, and pressing Return again is the
    /// whole of the retry.
    private func uploading(_ text: String, through cloud: CloudChatLink) async -> CloudUpload {
        let parsed = AttachmentDraft.parse(text)
        let paths = Array(Set(parsed.paths))
        guard !paths.isEmpty else { return .sent(text) }

        let root = AttachmentStaging.directory(draftID: session.id.rawValue)
        var moved: [String: String] = [:]
        for path in paths {
            let file = URL(filePath: (root as NSString).appendingPathComponent(path))
            guard let data = try? Data(contentsOf: file) else {
                return .refused(
                    title: "That file was not sent",
                    sentence: "\((path as NSString).lastPathComponent) is not on this Mac any more, so nothing was sent to the Cloud workspace."
                )
            }
            switch await cloud.upload(name: (path as NSString).lastPathComponent, data: data) {
            case .at(let remote):
                moved[path] = remote
            case .refused(let sentence):
                return .refused(title: "That file was not sent", sentence: sentence)
            }
        }

        // The staged copies have served their purpose the moment the machine has them, and they
        // are in the temporary directory rather than in a worktree somebody works in, so they go.
        // Only after every one of them arrived: a turn that is coming back to the composer has to
        // be sendable again by pressing Return.
        for path in moved.keys {
            try? FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent(path))
        }
        PromptAttachmentStore.shared.clear(sessionID: session.id.rawValue)
        return .sent(parsed.mapping { moved[$0] })
    }

    private func answerOnCloud(requestID: String, decision: PermissionDecision, through cloud: CloudChatLink) async {
        settle(PermissionResolution(requestID: requestID, decision: decision.storedName))
        refreshAwaitingPermission()
        guard let failure = await cloud.answer(requestID: requestID, decision: decision) else { return }
        if failure.code == .alreadyAnswered {
            // Somebody else got there first, which is how a shared question is meant to end.
            app.notice = BloomNotice(message: failure.message)
            return
        }
        if let index = rows.firstIndex(where: {
            $0.kind == .permissionAsk && PermissionAsk.decode(payload: $0.payload)?.requestID == requestID
        }) {
            foldCache.invalidate(row: index)
            rows[index].permissionDecision = nil
            presentationRevision += 1
        }
        refreshAwaitingPermission()
        app.alert = BloomAlert(title: "Could not send the answer", message: failure.message)
    }

    /// The composer's pickers, for a Cloud chat: last writer wins on the machine, and the event it
    /// sends back names who wrote it.
    private func updateCloudPreferences(
        through cloud: CloudChatLink, model: String?, effort: String?, permissionMode: PermissionMode?,
        interactionMode: InteractionMode?, agentKind: AgentKind?
    ) async {
        var next = session
        if let agentKind { next.agentKind = agentKind }
        if let model { next.model = model }
        if let effort { next.effort = effort }
        if let permissionMode { next.permissionMode = permissionMode }
        if let interactionMode { next.interactionMode = interactionMode }
        var controls = cloud.controls ?? ComposerControls(session: next, isFastMode: false, outputStyle: OutputStyle.defaultName)
        controls.agentKind = next.agentKind
        controls.model = next.model
        controls.effort = next.effort
        controls.permissionMode = next.permissionMode
        controls.interactionMode = next.interactionMode
        let previous = session
        session = next
        if let failure = await cloud.setComposer(controls) {
            session = previous
            app.alert = BloomAlert(title: "Could not change this chat", message: failure)
        }
    }
}

/// Small helpers that peek at a stored payload without decoding the whole event, used while
/// folding rows together. How a result went is read by `ToolResultSummary`, which lives in the
/// core so that telling a denial from a failure is covered by tests.
enum ParentProbe {
    static func parentToolUseID(_ payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return object["parent_tool_use_id"] as? String
    }
}

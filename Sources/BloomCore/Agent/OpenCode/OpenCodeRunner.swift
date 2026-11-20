import Foundation
import Synchronization

/// Supervises one `opencode acp` connection for one Bloom chat.
///
/// The shape is `GrokRunner`'s, deliberately: a long-lived process, the session id persisted the
/// moment it arrives so a crashed app can resume, every event written to the store before it
/// reaches the UI, and the same permission bookkeeping. What is OpenCode's own is in
/// `applyComposerSettings` and in how the permission mode reaches the process.
public actor OpenCodeRunner: SessionRunner {
    public nonisolated let agentKind = AgentKind.openCode
    public nonisolated let workspacePath: String
    public nonisolated let sessionID: SessionID

    private let store: Store
    private let makeClient: @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient

    private var session: Session
    private var client: OpenCodeClient?
    private var pumpTask: Task<Void, Never>?
    private var translation: OpenCodeTranslation
    private var openCodeSessionID: String?
    /// What the open session last said it offers, which decides whether an effort can be set.
    private var options = OpenCodeConfigOptions()
    /// Invalidates in-flight pump events when the client is replaced. A late `.closed` from a
    /// dead process must not drop the replacement.
    private var connectionGeneration: UInt64 = 0
    private var permissionConnectionID = UUID()

    private let grants: SessionGrants
    private var wireModel: String { ModelIdentifier.resolve(session.model).model }

    private var approvals: [String: ACPPermissionRequest] = [:]
    /// Rules allowed "for this session", answered by Bloom because OpenCode's own `allow_always`
    /// outlives the session. Forgotten with the process, as the prompt's sentence promises.
    private var sessionRules: Set<PermissionRule> = []

    private let connection = LiveConnection()
    private let pending = PendingAsks()
    private let handle = CodexTurnHandle()
    private let sink = AgentPresentationFeed()
    private var sendsInFlight = 0
    /// A /btw context sent with a prompt not yet proven taken. See `acknowledgeSideContext`.
    private var awaitingSideContextAcknowledgement = false
    /// OpenCode has no plan item: a plan turn's answer is its last text block, recorded as the
    /// plan when the turn ends normally. See "Plan mode" in `docs/OPENCODE.md`.
    private var turnMode = InteractionMode.build
    private var planCandidate: AgentTextBlock?
    private var wasEvicted = false
    private var trouble = PersistenceTrouble()
    private let bridge: BridgeAttachment?
    /// A cap on a provider announcement that never comes. Seen within four seconds on 2.3.2.
    private let announcementWait: Duration

    public init(
        workspacePath: String,
        session: Session,
        store: Store,
        bridge: BridgeAttachment? = nil,
        announcementWait: Duration = .seconds(10),
        makeClient: @escaping @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient = OpenCodeRunner.spawn
    ) {
        self.workspacePath = workspacePath
        self.sessionID = session.id
        self.session = session
        self.store = store
        self.bridge = bridge
        self.announcementWait = announcementWait
        self.makeClient = makeClient
        self.grants = SessionGrants(store: store, workspaceID: session.workspaceID)
        self.translation = OpenCodeTranslation(context: OpenCodeTranslation.Context(
            model: ModelIdentifier.resolve(session.model).model,
            cwd: workspacePath,
            permissionMode: session.permissionMode.cliValue
        ))
    }

    public static let spawn: @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient = { configuration in
        OpenCodeClient(configuration: configuration)
    }

    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    public nonisolated var presentationFeed: AgentPresentationFeed? { sink }

    public var isProcessAlive: Bool { connection.current?.isProcessAlive ?? false }

    public var currentSession: Session { session }

    public var lastPersistenceFailure: String? { trouble.lastSentence }

    public var persistenceFailureCount: Int { trouble.failures }

    static let clientVersion = "1.0"

    // MARK: - SessionRunner

    public func send(_ text: String, recording: Data? = nil) async throws {
        try await send(text, recording: recording, deliveryID: nil, interactionMode: nil)
    }

    public func evictIfIdle(for duration: Duration) async -> Bool {
        guard !wasEvicted, sendsInFlight == 0, !session.state.isMidTurn,
              session.agentSessionID != nil, pending.isEmpty, !sink.hasBackgroundWork else { return false }
        let lastActivity = sink.lastActivity
        guard lastActivity.duration(to: .now) >= duration,
              let waiting = try? await store.pendingDeliveries(sessionID: session.id), waiting.isEmpty else { return false }
        // Recheck after the store hop. A send or a native background event invalidates the lease.
        guard sendsInFlight == 0, !session.state.isMidTurn, pending.isEmpty,
              !sink.hasBackgroundWork, sink.lastActivity == lastActivity else { return false }
        wasEvicted = true
        terminateNow()
        return true
    }

    public func sendDelivery(_ delivery: Delivery) async throws {
        var mode = delivery.interactionMode
        if mode == nil { mode = try await store.session(id: sessionID)?.interactionMode }
        try await send(delivery.sent, recording: delivery.crewPayload,
                       deliveryID: delivery.id, interactionMode: mode)
    }

    /// `applyComposerSettings` reads these on the next send, so the process and its `ses_…` stay.
    public func adoptComposerSettings(model: String, effort: String) async {
        session.model = model
        session.effort = effort
    }

    private func send(_ text: String, recording: Data?, deliveryID: DeliveryID?,
                      interactionMode: InteractionMode?) async throws {
        guard !wasEvicted else { throw ProviderIdleError.retired }
        sendsInFlight += 1
        sink.noteActivity()
        defer { sendsInFlight -= 1 }
        let generation = handle.generation
        let replacement = handle.prepareReplacement()
        defer { handle.finishReplacement(replacement) }
        try handle.check(generation)
        if handle.wasCancelled {
            for event in translation.finishInterruptedTurn() { await emit(event) }
            try handle.check(generation)
        }
        let client = try await connected()
        try handle.check(generation)
        let openCodeSessionID = try await openSession(on: client)
        try handle.check(generation)
        // Before the settings: a model changed right after a stop is now set on the same session
        // while the stopped prompt winds down, and that overlap was never measured.
        await client.waitUntilNoPrompt()
        try handle.check(generation)
        try await applyComposerSettings(
            on: client, sessionID: openCodeSessionID, mode: interactionMode ?? session.interactionMode
        )
        try handle.check(generation)

        if deliveryID == nil {
            if let recording { await persist(kind: .crew, payload: recording) } else { await persist(kind: .user, payload: Self.userPayload(text)) }
        }
        try handle.check(generation)

        turnMode = interactionMode ?? session.interactionMode
        planCandidate = nil
        // A /btw conversation's first question carries the parent's context; the stored row does not.
        let prompt = try await store.sideConversationTurn(text, sessionID: sessionID)
        if let deliveryID { try await store.beginDeliveryDispatch(id: deliveryID) }
        // Before the prompt goes, so an answer handled during the await is the one that acknowledges.
        awaitingSideContextAcknowledgement = prompt != text
        let promptID = try await client.beginPrompt(sessionID: openCodeSessionID, text: prompt)
        if let deliveryID { try await store.acceptDelivery(id: deliveryID, providerTurnID: promptID.turnID) }
        guard handle.begin(turnID: promptID.turnID, generation: generation) else {
            await client.cancel(sessionID: openCodeSessionID)
            throw CancellationError()
        }

        session.apply(.turnStarted)
        await save(session)
    }

    public nonisolated func cancelNow() {
        let stopped = handle.markCancelled()
        Task { await self.stopTurn(stopped) }
    }

    private func stopTurn(_ stopped: CodexTurnHandle.Stopped) async {
        if handle.generation == stopped.generation, handle.wasCancelled {
            for event in translation.finishInterruptedTurn() { await emit(event) }
            await filePendingAsks()
        }
        if handle.generation == stopped.generation, handle.wasCancelled,
           session.apply(.cancelled).moves { await save(session) }
        if handle.generation == stopped.generation, handle.wasCancelled, let openCodeSessionID {
            await client?.cancel(sessionID: openCodeSessionID)
        }
    }

    public nonisolated func terminateNow() {
        sink.noteProcessEnded()
        handle.markCancelled()
        connection.current?.terminateNow()
        Task { await self.shutdown() }
    }

    public func answer(requestID: String, decision: PermissionDecision) async {
        guard let ask = pending.take(requestID) else { return }
        if case .allow(.session) = decision { sessionRules.formUnion(ask.rules) }
        let request = approvals[requestID]
        await write(answerTo: ask, decision: decision, request: request)
        await close(ask, as: decision.storedName, note: "")
        await grants.record(decision, from: ask)
    }

    public func shutdown() async {
        await filePendingAsks()
        // `retired`, not `cancelled`: this is the process going away, which on an idle chat is no stop.
        if session.apply(.retired).moves { await save(session) }
        await dropConnection()
    }

    private func dropConnection() async {
        connectionGeneration += 1
        let closing = client
        let sessionToClose = openCodeSessionID
        client = nil
        openCodeSessionID = nil
        pumpTask?.cancel()
        pumpTask = nil
        handle.end()
        approvals.removeAll()
        sessionRules.removeAll()
        for event in translation.finishInterruptedTurn() { await emit(event) }
        if let sessionToClose {
            await closing?.closeSession(sessionToClose)
        }
        await closing?.stop()
    }

    // MARK: - Connecting

    private func connected() async throws -> OpenCodeClient {
        if let client {
            if client.isProcessAlive, await client.isClosed == false {
                return client
            }
            await dropConnection()
        }

        let stored = try? await store.setting(AgentCatalog.executablePathSettingKey(.openCode))
        let client = makeClient(OpenCodeClient.Configuration(
            executable: AgentCatalog.executable(for: .openCode, override: stored),
            cwd: workspacePath,
            clientName: "Bloom",
            clientVersion: Self.clientVersion,
            permissionMode: session.permissionMode
        ))
        self.client = client
        permissionConnectionID = UUID()
        connection.attach(client)
        let events = client.events
        let generation = connectionGeneration
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, from: generation)
            }
        }
        try await client.start()
        return client
    }

    private func openSession(on client: OpenCodeClient) async throws -> String {
        if let openCodeSessionID { return openCodeSessionID }

        let servers = BridgeRegistration.openCodeServers(bridge)
        let opened: OpenCodeSession
        if let stored = session.agentSessionID, !stored.isEmpty {
            do {
                opened = try await client.resumeSession(stored, cwd: workspacePath, mcpServers: servers)
            } catch let error as ACPRPCError where Self.sessionIsGone(error) {
                opened = try await client.newSession(cwd: workspacePath, mcpServers: servers)
            }
        } else {
            opened = try await client.newSession(cwd: workspacePath, mcpServers: servers)
        }

        options = opened.options
        openCodeSessionID = opened.id
        translation.context.permissionMode = session.permissionMode.cliValue
        for event in translation.translate(.sessionReady(opened)) {
            await emit(event)
        }
        if session.agentSessionID != opened.id {
            session = session.with {
                $0.agentSessionID = opened.id
                $0.updatedAt = Date()
            }
            await save(session)
        }
        return opened.id
    }

    static let invalidParamsCode = -32602

    /// Whether a refused resume means the stored session cannot come back, measured on 2.3.2 as
    /// `-32602` "session not found" or "does not belong to cwd". Anything else (a timeout, a dead
    /// connection) keeps the stored id, so the next send resumes rather than forgets the chat.
    /// "session" and "not found" are matched apart, so "Session ses_x not found" still counts and
    /// another thing not found does not forget the chat.
    static func sessionIsGone(_ error: ACPRPCError) -> Bool {
        let message = error.message.lowercased()
        let gone = message.contains("session") && message.contains("not found")
        return error.code == invalidParamsCode && (gone || message.contains("does not belong to cwd"))
    }

    /// Sets the composer's model, then the work mode, then the effort if that model offers it.
    ///
    /// The effort option belongs to the current model and is absent for a model with no levels,
    /// so it is read back from the model's own reply. An effort left over from another model is
    /// dropped without a word rather than sent and refused.
    private func applyComposerSettings(
        on client: OpenCodeClient, sessionID: String, mode: InteractionMode
    ) async throws {
        // One snapshot: a change adopted during the awaits below belongs to the next send.
        let model = wireModel
        let effort = session.effort
        if !model.isEmpty {
            options = try await select(model, on: client, sessionID: sessionID)
            translation.context.model = model
        }
        try await selectMode(mode, on: client, sessionID: sessionID)
        guard !effort.isEmpty, options.offersEffort(effort),
              options.currentEffort != effort else { return }
        do {
            options = try await client.setConfigOption(
                sessionID: sessionID, configID: OpenCodeConfigOptions.effortID, value: effort
            )
        } catch let error as ACPClientError {
            // A dead connection must fail the send. Anything else leaves the model's own effort.
            switch error {
            case .connectionClosed, .notInitialized: throw error
            case .timedOut, .unexpectedResult: return
            }
        } catch {
            return
        }
    }

    /// The mode is stored with the session and survives a resume and a model change, so `build` is
    /// sent as well as `plan` whenever the session says otherwise. Unlike the effort, a mode that
    /// cannot be set fails the send: a plan turn run as `build` would edit the worktree.
    private func selectMode(_ mode: InteractionMode, on client: OpenCodeClient, sessionID: String) async throws {
        let wanted = mode.rawValue
        guard options.currentMode != wanted else { return }
        guard options.offersMode(wanted) else {
            // A session that cannot build stays on what it has: only a plan run as `build` edits.
            if mode == .build { return }
            throw OpenCodeRunnerError.modeUnavailable(mode: wanted)
        }
        options = try await client.setConfigOption(
            sessionID: sessionID, configID: OpenCodeConfigOptions.modeID, value: wanted
        )
    }

    /// A refused model fails the turn, unlike Grok's: the session would otherwise keep OpenCode's
    /// default, a hosted model nobody picked. A local provider can be detected after the session
    /// opens, so a refusal waits once for an announcement that offers the model.
    private func select(
        _ model: String, on client: OpenCodeClient, sessionID: String
    ) async throws -> OpenCodeConfigOptions {
        do {
            return try await setModel(model, on: client, sessionID: sessionID)
        } catch let error as ACPRPCError {
            guard await client.waitUntilOffered(model, within: announcementWait) else {
                throw OpenCodeRunnerError.modelRefused(model: model, reason: error.message)
            }
        }
        do {
            return try await setModel(model, on: client, sessionID: sessionID)
        } catch let error as ACPRPCError {
            throw OpenCodeRunnerError.modelRefused(model: model, reason: error.message)
        }
    }

    private func setModel(
        _ model: String, on client: OpenCodeClient, sessionID: String
    ) async throws -> OpenCodeConfigOptions {
        try await client.setConfigOption(
            sessionID: sessionID, configID: OpenCodeConfigOptions.modelID, value: model
        )
    }

    // MARK: - Events

    private func recordPlan(endingWith result: AgentResult) async {
        defer { planCandidate = nil }
        guard turnMode == .plan, result.stopReason == "end_turn", let plan = planCandidate,
              OpenCodePlanReply.isPlan(plan.text) else { return }
        do {
            _ = try await store.recordPlan(sessionID: session.id, sourceID: plan.messageID, markdown: plan.text)
        } catch {
            await report("could not save the proposed plan", error)
        }
    }

    private func handle(_ event: OpenCodeEvent, from generation: UInt64) async {
        guard generation == connectionGeneration else { return }

        if case .closed = event, handle.wasCancelled || trouble.hasStopped { return }
        if case .closed = event {
            // The process that asked is gone: its questions are stopped, never answered later,
            // or a late answer would record a grant for a call that can no longer run.
            approvals.removeAll()
            await filePendingAsks()
        }

        if case .permission(let request) = event {
            if handle.wasCancelled {
                await client?.answer(request.id, with: OpenCodePermission.cancelledResult)
                return
            }
            await ask(request)
            return
        }

        if case .update = event, handle.wasCancelled { return }

        let ending = if case .promptCompleted(let result) = event { result.requestID.turnID } else { nil as String? }
        if let ending, !handle.acceptsTerminal(turnID: ending) { return }

        for translated in translation.translate(event) {
            await emit(translated, endingTurn: ending)
        }
    }

    /// `beginPrompt` returns once the frame is written, and a refusal arrives later as the turn's
    /// result. The first answer or thought is what proves the prompt was taken, as in `AgentRunner`,
    /// so a refused first question is retried with the parent's context still on it.
    private func acknowledgeSideContext() async {
        guard awaitingSideContextAcknowledgement else { return }
        do {
            try await store.acknowledgeSideConversationContext(sessionID: sessionID)
            awaitingSideContextAcknowledgement = false
        } catch {
            // Repeating the context is safer than losing it after a failed write.
            Self.log.error("could not acknowledge side context: \(error.readableMessage, privacy: .public)")
        }
    }

    private func emit(_ event: AgentEvent, endingTurn: String? = nil) async {
        let intent = handle.intent
        var storedMessage: Message?
        if event.isTranscriptRow {
            storedMessage = await persist(
                kind: event.kind,
                payload: event.raw.isEmpty ? Data("{}".utf8) : event.raw,
                refID: event.refID
            )
        }

        if let endingTurn, !handle.acceptsTerminal(turnID: endingTurn, intent: intent) { return }

        switch event {
        case .assistantText(let block):
            planCandidate = block
            await acknowledgeSideContext()

        case .thinking:
            await acknowledgeSideContext()

        case .result(let result):
            handle.end()
            await recordPlan(endingWith: result)
            session.apply(.turnFinished(isError: result.isError))
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                if result.usage.contextTokens > 0 { $0.contextTokens = result.usage.contextTokens }
            }
            await save(session)

        case .error:
            handle.end()
            session.apply(.turnFinished(isError: true))
            await save(session)

        default:
            break
        }

        if let endingTurn, !handle.acceptsTerminal(turnID: endingTurn, intent: intent) { return }
        sink.yield(event, messageSeq: storedMessage?.seq)
    }

    // MARK: - Asking

    private func ask(_ request: ACPPermissionRequest) async {
        let ask = OpenCodePermission.ask(for: request, connectionID: permissionConnectionID)
        // Decided before the first await and never queued, so no answer from a person can land
        // on a question the session grant is about to answer.
        let bySession = PermissionGrantIndex.covers(ask: ask, sessionRules: sessionRules)
        if !bySession { pending.add(ask) }
        approvals[ask.requestID] = request

        do {
            try await store.appendPermissionAsk(sessionID: session.id, ask: ask)
        } catch {
            await report("could not store a permission question", error)
        }
        await persist(kind: .permissionAsk, payload: ask.raw, refID: ask.toolUseID)
        // A question the session grant answers is shown with its answer, not before it: drawn
        // first, it flashed as a card across the store write in between.
        if !bySession { sink.yield(.permissionAsk(ask)) }

        if bySession {
            // A stop or a closed process during the awaits above wins, as it would for a queued
            // question: `filePendingAsks` cannot see this one, so it is stopped here instead.
            guard !handle.wasCancelled, approvals[ask.requestID] != nil else {
                if approvals.removeValue(forKey: ask.requestID) != nil {
                    await client?.answer(request.id, with: OpenCodePermission.cancelledResult)
                }
                await close(ask, as: PermissionAskOutcome.stopped, note: "", drawingTheCard: true)
                return
            }
            await write(answerTo: ask, decision: .allow(scope: .session), request: request)
            // Stored as a session allow, not `auto`, which reads back as a project grant.
            await close(
                ask,
                as: PermissionDecision.allow(scope: .session).storedName,
                note: PermissionGrantIndex.sessionNote(for: ask),
                drawingTheCard: true
            )
            return
        }

        let matched = await grants.matching(ask)
        if let matched, let claimed = pending.take(ask.requestID) {
            await write(answerTo: claimed, decision: .allow(scope: .session), request: request)
            await close(claimed, as: PermissionAskOutcome.auto, note: PermissionGrantIndex.note(for: matched))
            await grants.recordUse(of: matched)
            return
        }

        guard matched == nil, pending.contains(ask.requestID) else { return }
        session.apply(.blocked)
        await save(session)
    }

    /// Stop and quit answer pending asks as ACP `cancelled`, which decides nothing about the tool.
    private func filePendingAsks() async {
        for ask in pending.drain() {
            if let request = approvals[ask.requestID] {
                await client?.answer(request.id, with: OpenCodePermission.cancelledResult)
            }
            await close(ask, as: PermissionAskOutcome.stopped, note: "")
        }
        if session.apply(.unblocked).moves { await save(session) }
    }

    private func write(
        answerTo ask: PermissionAsk,
        decision: PermissionDecision,
        request: ACPPermissionRequest?
    ) async {
        if let request {
            if let optionID = OpenCodePermission.optionID(for: decision, in: request) {
                await client?.answer(request.id, with: OpenCodePermission.selectedResult(optionID: optionID))
            } else {
                await client?.answer(request.id, with: OpenCodePermission.cancelledResult)
            }
        }
        approvals[ask.requestID] = nil
        guard pending.isEmpty else { return }
        guard session.apply(.unblocked).moves else { return }
        await save(session)
    }

    /// - Parameter drawingTheCard: for a question never drawn yet, which is drawn here with its
    ///   answer, the two yielded back to back so no card shows on its own in between.
    private func close(
        _ ask: PermissionAsk, as decision: String, note: String, drawingTheCard: Bool = false
    ) async {
        pending.remove(ask.requestID)
        approvals[ask.requestID] = nil
        do {
            try await store.resolvePermissionAsk(id: ask.requestID, decision: decision)
        } catch {
            await report("could not record a permission decision", error)
        }
        if drawingTheCard { sink.yield(.permissionAsk(ask)) }
        sink.yield(.permissionDecided(PermissionResolution(
            requestID: ask.requestID,
            toolUseID: ask.toolUseID,
            decision: decision,
            note: note
        )))
    }

    // MARK: - Storage

    static func userPayload(_ text: String) -> Data {
        let json = JSONValue.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ]),
        ])
        return Data(json.compactJSON.utf8)
    }

    @discardableResult
    private func persist(kind: MessageKind, payload: Data, refID: String? = nil) async -> Message? {
        do {
            return try await store.appendNext(
                sessionID: session.id,
                kind: kind,
                payload: payload,
                refID: refID
            )
        } catch {
            await report("could not store a \(kind.rawValue) row", error)
            return nil
        }
    }

    private func save(_ session: Session) async {
        do {
            try await store.update(sessionID: session.id) {
                $0.agentSessionID = session.agentSessionID
                $0.state = session.state
                $0.inputTokens = session.inputTokens
                $0.outputTokens = session.outputTokens
                $0.contextTokens = session.contextTokens
                $0.updatedAt = session.updatedAt
            }
        } catch {
            await report("could not save the session", error)
        }
    }

    private func report(_ what: String, _ error: Error) async {
        Self.log.error("\(what, privacy: .public): \(error.readableMessage, privacy: .public)")

        let standing = await TranscriptStanding.of(sessionID: session.id, in: store)
        switch trouble.record(WorkspaceTrouble.recording(
            transcript: standing, complaint: TranscriptStanding.complaint(about: error)
        )) {
        case .tell(let sentence):
            sink.yield(.error(.storage(message: sentence)))
        case .stop:
            Self.log.info("the transcript for \(self.session.id.rawValue, privacy: .public) has been removed, so this run is being stopped without a word")
            terminateNow()
        case .alreadyStopped:
            break
        }
    }

    var transcriptWasRemoved: Bool { trouble.hasStopped }

    private static let log = CoreLogger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.spatie.bloom",
        category: "opencode-runner"
    )
}

public enum OpenCodeRunnerError: Error, Equatable, LocalizedError {
    case modelRefused(model: String, reason: String)
    case modeUnavailable(mode: String)

    public var errorDescription: String? {
        switch self {
        case .modelRefused(let model, let reason):
            "OpenCode could not select \(model): \(reason)"
        case .modeUnavailable(let mode):
            "This OpenCode session offers no \(mode) mode."
        }
    }
}

private final class LiveConnection: Sendable {
    private let client = Mutex<OpenCodeClient?>(nil)

    var current: OpenCodeClient? { client.withLock { $0 } }

    func attach(_ client: OpenCodeClient) {
        self.client.withLock { $0 = client }
    }
}

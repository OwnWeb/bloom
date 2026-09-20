import BloomProtocol
import Foundation

/// The prompts waiting in a Cloud workspace, drained whether or not anybody is connected.
///
/// **In the order the server received them, whoever sent them.** Several people prompt in one
/// chat, and nothing is ever injected into a running turn: a prompt from somebody else waits
/// behind it, even on a backend that would read a line written mid-turn, because a person should
/// not find their turn redirected by a colleague's sentence arriving in the middle of it.
///
/// The durability is `Store`'s delivery states, the same ones the Mac drains through: a claim
/// writes the user row, dispatch marks the attempt uncertain before a byte reaches the agent, and
/// acceptance retires it. So after a crash a prompt that may have reached the agent is shown as
/// uncertain and waits for a person, rather than being sent twice.
///
/// **runbloom.app decides whether a turn may start, and with which key.** Each prompt was
/// registered when it was sent, while its author's token was fresh; here, at the front of the
/// queue, the turn is started, which answers with a key or a refusal. A refusal for a team limit
/// leaves the prompt queued and marked, and the queue stops asking: polling would keep the machine
/// awake, which is the cost the limit exists to cap. `retryBlocked()` is what runbloom.app's
/// `limits-cleared` call and every wake end up in.
actor RemotePromptQueue {
    typealias LoadSession = @Sendable (SessionID) async throws -> RemoteSession

    private let store: Store
    private let gate: any RemoteTurnGate
    private let load: LoadSession
    /// Whether a chat's prompts must wait without that being an error: setup is still running.
    private let held: @Sendable (SessionID) async -> Bool
    private let changed: @Sendable (SessionID) async -> Void
    private let settled: @Sendable (SessionID, RemoteTurnEnd, String?) async -> Void
    private let started: @Sendable (SessionID, Delivery) async -> Void
    /// Handed every grant before its chat's process is prepared, so a team key arriving while
    /// other processes hold personal ones retires those.
    private let granted: @Sendable (RemoteTurnGrant) async -> Void

    private var tasks: [SessionID: Task<Void, Never>] = [:]
    private var errors: [SessionID: String] = [:]
    private var blocked: Set<SessionID> = []
    private var cancellations: [SessionID: Int] = [:]
    /// The runbloom.app turn each chat is running, ended when the turn comes to rest.
    private var running: [SessionID: String] = [:]
    /// Whose turn each chat is running, so a revoke can find it.
    private var runningAuthors: [SessionID: String] = [:]
    private var closed = false

    init(
        store: Store,
        gate: any RemoteTurnGate,
        load: @escaping LoadSession,
        held: @escaping @Sendable (SessionID) async -> Bool = { _ in false },
        changed: @escaping @Sendable (SessionID) async -> Void = { _ in },
        started: @escaping @Sendable (SessionID, Delivery) async -> Void = { _, _ in },
        settled: @escaping @Sendable (SessionID, RemoteTurnEnd, String?) async -> Void = { _, _, _ in },
        granted: @escaping @Sendable (RemoteTurnGrant) async -> Void = { _ in }
    ) {
        self.granted = granted
        self.store = store
        self.gate = gate
        self.load = load
        self.held = held
        self.changed = changed
        self.settled = settled
        self.started = started
    }

    static func pauseKey(_ id: SessionID) -> String { "remote.queue.paused." + id.rawValue }
    static let pausedSentence = "Queue paused. Send a message to resume."

    var isDraining: Bool { !tasks.isEmpty }
    var drainingChats: Set<SessionID> { Set(tasks.keys) }
    var hasRunningTurn: Bool { !running.isEmpty }

    // MARK: - Asking

    /// Registers the prompt with runbloom.app under its author's token, then queues it. A refusal
    /// to register (no GitHub, no ability) reaches the sender as a failure and queues nothing.
    func enqueue(_ text: String, session: Session, caller: RemoteCaller, mention: String? = nil,
                 via: MessageVia? = nil) async throws -> DeliveryID {
        guard !closed else { throw RemoteFailure.shuttingDown }
        let turnID = try await gate.register(.turn, chat: session.id, agent: session.agentKind, caller: caller)
        // The mention travels with the prompt so the transcript keeps it and the agent does not
        // read it; see `Delivery.sent`.
        let delivery = Delivery(targetSessionID: session.id, body: text, interactionMode: session.interactionMode,
                                author: caller.author, audienceMention: mention,
                                remoteTurnID: turnID.isEmpty ? nil : turnID, via: via)
        _ = try await store.enqueueDelivery(delivery)
        // Somebody sending a message is somebody asking for the queue to move again.
        try await store.setSetting(Self.pauseKey(session.id), nil)
        errors.removeValue(forKey: session.id)
        await changed(session.id)
        start(session.id)
        return delivery.id
    }

    /// A delivery the runtime built itself, such as a subagent's report to its parent. Not
    /// registered: it is not a person's turn, and it runs on the key its chat already has.
    func enqueue(_ delivery: Delivery) async throws {
        guard !closed else { throw RemoteFailure.shuttingDown }
        _ = try await store.enqueueDelivery(delivery)
        await changed(delivery.targetSessionID)
        start(delivery.targetSessionID)
    }

    func cancel(_ deliveryID: DeliveryID, sessionID: SessionID) async throws {
        guard !closed else { throw RemoteFailure.shuttingDown }
        cancellations[sessionID, default: 0] += 1
        // The drain is held off while the row goes, so it cannot claim the prompt being removed.
        defer {
            let remaining = (cancellations[sessionID] ?? 1) - 1
            cancellations[sessionID] = remaining == 0 ? nil : remaining
            // The prompt that was blocked may be the one removed, and the ones behind it may run on
            // a key no limit applies to; the next start blocks the chat again if not.
            blocked.remove(sessionID)
            start(sessionID)
        }
        let task = tasks[sessionID]
        task?.cancel()
        await task?.value
        guard let delivery = try await store.pendingDeliveries(sessionID: sessionID).first(where: { $0.id == deliveryID }),
              try await store.cancelDelivery(id: deliveryID) else {
            throw RemoteFailure(.conflict, "This message has already been sent. Stop the current turn instead.")
        }
        if let turnID = delivery.remoteTurnID { await gate.end(turnID: turnID) }
        errors.removeValue(forKey: sessionID)
        await changed(sessionID)
    }

    /// Somebody lost access. Their queued prompts are removed, since runbloom.app would refuse
    /// each at the front of the queue and pause the chat for everybody behind it. Answers the
    /// chats running one of their turns, for the runtime to stop.
    func revoke(userID: String, sessions: [SessionID]) async -> [SessionID] {
        guard !closed else { return [] }
        for id in sessions {
            let theirs = ((try? await store.pendingDeliveries(sessionID: id)) ?? [])
                .filter { $0.author?.userID == userID && $0.state == .pending }
            for delivery in theirs {
                try? await cancel(delivery.id, sessionID: id)
            }
        }
        return runningAuthors.filter { $0.value == userID }.map(\.key)
    }

    func pause(_ id: SessionID) async throws {
        try await store.setSetting(Self.pauseKey(id), "true")
        let task = tasks[id]
        task?.cancel()
        await task?.value
        errors[id] = Self.pausedSentence
        await changed(id)
    }

    /// Tries every blocked chat again: a limit lifted, or the machine woke for something else.
    func retryBlocked() {
        let waiting = blocked
        blocked.removeAll()
        for id in waiting { start(id) }
    }

    /// Picks up what a previous run of the server left: paused chats stay paused, and chats with
    /// prompts waiting start draining. A claim that never reached dispatch goes back to pending.
    func restore(sessions: [SessionID]) async throws {
        try await store.recoverDeliveryClaims()
        for id in sessions {
            if try await store.setting(Self.pauseKey(id)) == "true" {
                errors[id] = Self.pausedSentence
            } else if try await !store.pendingDeliveries(sessionID: id).isEmpty {
                start(id)
            }
        }
    }

    func resume(_ id: SessionID) { start(id) }

    // MARK: - Reading

    func record(_ id: SessionID) async throws -> QueueRecord {
        let pending = try await store.pendingDeliveries(sessionID: id)
        return QueueRecord(chatID: id.rawValue, prompts: pending.map(\.queuedRecord), error: errors[id])
    }

    // MARK: - Turns ending

    /// The runbloom.app turn a chat is running, if any.
    func runningTurn(_ id: SessionID) -> String? { running[id] }
    /// The person whose turn a chat is running, as runbloom.app registered it.
    func runningAuthor(_ id: SessionID) -> String? { runningAuthors[id] }

    func turnEnded(_ id: SessionID, ending: RemoteTurnEnd) async {
        runningAuthors.removeValue(forKey: id)
        let turnID = running.removeValue(forKey: id)
        if let turnID { await gate.end(turnID: turnID) }
        guard !closed else { return }
        if ending.isFailure {
            errors[id] = ending.summary.isEmpty ? Self.pausedSentence : ending.summary
            try? await store.setSetting(Self.pauseKey(id), "true")
            await changed(id)
        }
        await settled(id, ending, turnID)
        start(id)
    }

    static let shutdownSentence = "The Bloom Cloud workspace stopped while this turn was running."

    func shutdown() async {
        closed = true
        let pending = Array(tasks.values)
        tasks.removeAll()
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        // A turn still running is ended here, and settled too: its usage has to say it finished
        // before the machine's last report, or runbloom.app keeps it open against the team.
        let stillRunning = running
        running.removeAll()
        for (id, turnID) in stillRunning {
            await gate.end(turnID: turnID)
            await settled(id, .stopped(Self.shutdownSentence), turnID)
        }
    }

    // MARK: - Draining

    private func start(_ id: SessionID) {
        guard tasks[id] == nil, !closed, cancellations[id] == nil, !blocked.contains(id) else { return }
        tasks[id] = Task {
            await self.drain(id)
            // An enqueue can land while the last empty read is on its way back from the store, so
            // look again once the slot is free, or that prompt would sit there until the next one.
            await self.restartIfPending(id)
        }
    }

    private func restartIfPending(_ id: SessionID) async {
        // Held is checked here as well as in `drain`, or a held drain returning would restart
        // itself at once and spin for the whole of the setup run.
        guard !closed, !Task.isCancelled, errors[id] == nil, !blocked.contains(id), tasks[id] == nil, await !held(id),
              (try? await store.setting(Self.pauseKey(id))) != "true",
              let pending = try? await store.pendingDeliveries(sessionID: id),
              pending.contains(where: { $0.state == .pending }) else { return }
        start(id)
    }

    private func drain(_ id: SessionID) async {
        defer { tasks.removeValue(forKey: id) }
        do {
            while !Task.isCancelled, !closed, errors[id] == nil,
                  try await store.setting(Self.pauseKey(id)) != "true",
                  let delivery = try await store.pendingDeliveries(sessionID: id).first {
                if await held(id) { return }
                guard delivery.state == .pending else {
                    errors[id] = "A previous message may have reached the agent before the server stopped. "
                        + "Check the conversation, then remove that queued message before continuing."
                    await changed(id)
                    return
                }
                let live = try await load(id)
                try await live.refreshState(store: store, sessionID: id)
                if await live.isBusy {
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                // A stop or a failure can land while the session loads; its pause wins.
                guard errors[id] == nil, try await store.setting(Self.pauseKey(id)) != "true" else { return }
                try Task.checkCancellation()

                let agent = try await store.session(id: id)?.agentKind ?? .claudeCode
                // Started at runbloom.app but not yet handed to the agent. A failure or a
                // cancellation in that gap ends it, or it counts against the team until somebody
                // resumes the queue.
                var startedTurn: String?
                defer {
                    if let startedTurn { Task { [gate] in await gate.end(turnID: startedTurn) } }
                }
                if let turnID = delivery.remoteTurnID {
                    let grant: RemoteTurnGrant
                    do {
                        grant = try await gate.start(turnID: turnID)
                    } catch let refusal as RemoteTurnRefusal {
                        try await refuse(delivery, refusal)
                        return
                    }
                    startedTurn = turnID
                    if delivery.block != nil { try await store.setDeliveryBlock(id: delivery.id, nil) }
                    await granted(grant)
                    try await live.prepare(identity: grant.launchIdentity(for: agent), environment: grant.environment(for: agent),
                                           personal: grant.personalMarks(for: [agent]))
                } else {
                    // Not a person's turn, such as a subagent's report reaching its parent: it
                    // runs on whatever key the chat's process already has.
                    try await live.prepare(identity: nil, environment: [:])
                }

                guard try await store.claimDelivery(id: delivery.id) else { continue }
                if let turnID = delivery.remoteTurnID { running[id] = turnID }
                // From here the turn is `running`'s to end, on every path.
                startedTurn = nil
                runningAuthors[id] = delivery.author?.userID
                await changed(id)
                await started(id, delivery)
                do {
                    // Its own task, so cancelling the drain pauses the queue rather than a runner
                    // halfway through writing a turn.
                    let send = Task { try await live.send(delivery) }
                    try await send.value
                } catch {
                    // Nothing reached the agent while the claim still stands, so it is pending
                    // again; an attempt that got as far as dispatch stays uncertain.
                    try? await store.releaseDeliveryClaim(id: delivery.id)
                    if let turnID = running.removeValue(forKey: id) { await gate.end(turnID: turnID) }
                    errors[id] = error.localizedDescription
                    try? await store.setSetting(Self.pauseKey(id), "true")
                    await changed(id)
                    return
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            errors[id] = error.localizedDescription
            try? await store.setSetting(Self.pauseKey(id), "true")
            await changed(id)
        }
    }

    private func refuse(_ delivery: Delivery, _ refusal: RemoteTurnRefusal) async throws {
        let id = delivery.targetSessionID
        switch refusal {
        case .blocked(let block):
            try await store.setDeliveryBlock(id: delivery.id, block)
            blocked.insert(id)
        case .refused(_, let message):
            errors[id] = message
            try await store.setSetting(Self.pauseKey(id), "true")
        }
        await changed(id)
    }
}

extension Delivery {
    var queuedRecord: QueuedPromptRecord {
        let wireState = state == .uncertain ? "uncertain" : (block == nil ? "queued" : "blocked")
        return QueuedPromptRecord(
            id: id.rawValue, text: body, author: author?.record, state: wireState,
            blocked: block.map { BlockedRecord(limit: $0.limit, message: $0.message) }, createdAt: createdAt
        )
    }
}

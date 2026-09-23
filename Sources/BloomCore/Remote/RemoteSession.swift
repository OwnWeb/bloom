import Foundation

/// One chat's live agent in a Cloud workspace, owned by the runtime rather than by any connection.
///
/// **Nobody's disconnect can cancel an agent or abandon a question.** A client going away closes
/// its stream and nothing else; the turn, its questions and its queue carry on and are there for
/// whoever opens the workspace next. This is #163's `ServerSession`, which earned that rule, with
/// one thing added: the process is launched with the key of the person whose turn it is running.
///
/// **A process keeps its key for as long as turns keep resolving to the same one.** The identity
/// compared is the key's hash and the personal environment, never the person, so two teammates
/// on the team key share one long-lived process. A turn on a different key waits for the current
/// turn to end, stops the process and starts it again with `--resume`, which reloads the
/// conversation from the machine's own files. That costs a prompt cache miss, which is why it
/// happens only when the key actually changes. See docs/REMOTE-WORKSPACES.md.
actor RemoteSession {
    typealias MakeRunner = @Sendable (_ environment: [String: String], _ context: RemoteLaunchContext?) async throws -> any SessionRunner

    private let make: MakeRunner
    private(set) var runner: (any SessionRunner)?
    private var launchIdentity: String?
    /// What the running process holds of one person's, from `RemoteTurnGrant.personalMarks`.
    private(set) var personalMarks: Set<String> = []
    /// Set when a turn is stopped because its key must go, so the turn ends with that sentence
    /// rather than whatever the agent printed on its way out.
    private var stopReason: String?
    private(set) var isBusy = false
    /// When the turn in progress was sent, for the summary's `running_since`.
    private(set) var busySince: Date?
    private(set) var streamingText = ""
    private var eventTask: Task<Void, Never>?
    private var isClosed = false
    /// Invalidates a runner factory which is suspended while shutdown or a newer prepare wins.
    private var prepareGeneration = 0
    private var isSending = false
    private var generation = 0
    private var answering: Set<String> = []
    private var claimedEnd = false
    private var wasStopped = false
    private let onTurnEnded: @Sendable (RemoteTurnEnd) async -> Void
    /// After a turn is released, which is later than `onTurnEnded`: a summary built from that
    /// callback still read the chat as busy, and nothing asked again, so runbloom.app listed the
    /// workspace as running until something unrelated changed.
    private let onIdle: @Sendable () async -> Void
    private let onStream: @Sendable (_ text: String, _ reset: Bool) async -> Void
    /// How long shutdown waits for a terminated runner to exit. See `shutdown()`.
    private let runnerExitGrace: Duration
    private let retiresRunnerAfterTurn: Bool

    /// What the running process was launched with, so a turn whose conversation could not be
    /// resumed can launch again on the same key. See `restartWithoutResume`.
    private struct Launch {
        let identity: String?
        let environment: [String: String]
        let personal: Set<String>
        let context: RemoteLaunchContext?
    }

    private var launch: Launch?
    /// The turn in progress, kept for the same reason.
    private var turnDelivery: Delivery?
    /// Whether this turn has already been launched again once. Twice would be a loop.
    private var restartedTurn = false

    init(
        runnerExitGrace: Duration = .seconds(6),
        retiresRunnerAfterTurn: Bool = false,
        make: @escaping MakeRunner,
        onStream: @escaping @Sendable (_ text: String, _ reset: Bool) async -> Void = { _, _ in },
        onTurnEnded: @escaping @Sendable (RemoteTurnEnd) async -> Void = { _ in },
        onIdle: @escaping @Sendable () async -> Void = {}
    ) {
        self.onIdle = onIdle
        self.make = make
        self.runnerExitGrace = runnerExitGrace
        self.retiresRunnerAfterTurn = retiresRunnerAfterTurn
        self.onStream = onStream
        self.onTurnEnded = onTurnEnded
    }

    /// Makes sure the process that takes the next turn was launched with this identity, relaunching
    /// it when it was not. Only ever called between turns: the queue waits for `isBusy` to clear.
    ///
    /// A nil identity keeps whatever process is there, and launches one with no key when there
    /// is none: a turn nobody in particular asked for runs on the key the chat already has.
    func prepare(identity: String?, environment: [String: String], personal: Set<String> = [],
                 context: RemoteLaunchContext? = nil) async throws {
        guard !isClosed else { throw RemoteFailure(.unavailable, "This conversation is closed.") }
        guard !isBusy else { throw RemoteFailure(.busy, "The agent is busy. Wait for it to finish or stop it first.") }
        if !retiresRunnerAfterTurn, runner != nil, identity == nil || launchIdentity == identity { return }
        prepareGeneration += 1
        let preparing = prepareGeneration
        if runner != nil { await retireRunner() }
        guard !isClosed, preparing == prepareGeneration else {
            if isClosed { throw RemoteFailure(.unavailable, "This conversation is closed.") }
            throw RemoteFailure(.busy, "Another agent launch replaced this one.")
        }
        let fresh = try await make(environment, context)
        guard !isClosed, preparing == prepareGeneration, runner == nil else {
            await retire(fresh)
            if isClosed { throw RemoteFailure(.unavailable, "This conversation is closed.") }
            throw RemoteFailure(.busy, "Another agent launch replaced this one.")
        }
        install(fresh, as: Launch(identity: identity, environment: environment, personal: personal, context: context))
    }

    private func install(_ fresh: any SessionRunner, as launch: Launch) {
        runner = fresh
        launchIdentity = launch.identity
        personalMarks = launch.personal
        self.launch = launch
        let events = fresh.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.receive(event)
            }
        }
    }

    func send(_ delivery: Delivery) async throws {
        guard !isClosed else { throw RemoteFailure(.unavailable, "This conversation is closed.") }
        guard let runner else { throw RemoteFailure(.internal, "The agent was not started before its turn.") }
        guard !isBusy else { throw RemoteFailure(.busy, "The agent is busy. Wait for it to finish or stop it first.") }
        isBusy = true
        busySince = Date()
        isSending = true
        wasStopped = false
        stopReason = nil
        claimedEnd = false
        turnDelivery = delivery
        restartedTurn = false
        generation += 1
        defer { isSending = false }
        if !streamingText.isEmpty {
            streamingText = ""
            await onStream("", true)
        }
        do {
            try await runner.sendDelivery(delivery)
        } catch {
            let ending = claimEnd()
                ? (wasStopped ? RemoteTurnEnd.stopped(stopReason ?? error.localizedDescription)
                    : .failed(error.localizedDescription))
                : nil
            await closeTurn(ending, retiring: retiresRunnerAfterTurn)
            endTurn()
            throw error
        }
    }

    private func receive(_ event: AgentEvent) async {
        switch event {
        case .streamDelta(.text(let text)):
            // The durable transcript stays complete; only the transient tail is bounded.
            streamingText += text
            if streamingText.utf8.count > 262_144 {
                streamingText = String(streamingText.suffix(65_536))
                await onStream(streamingText, true)
            } else {
                await onStream(text, false)
            }
        case .assistantText:
            streamingText = ""
            await onStream("", true)
        case .result(let result):
            if ConversationNotResumed.matches(result), await restartWithoutResume() { return }
            guard claimEnd() else { return }
            streamingText = ""
            await onStream("", true)
            await closeTurn(
                wasStopped ? .stopped(stopReason ?? result.summary) : (result.isError ? .failed(result.summary) : .completed(result.summary)),
                retiring: retiresRunnerAfterTurn
            )
            endTurn()
        case .error(let error):
            if ConversationNotResumed.matches(error.message), await restartWithoutResume() { return }
            guard claimEnd() else { return }
            streamingText = ""
            await onStream("", true)
            await closeTurn(wasStopped ? .stopped(stopReason ?? error.message) : .failed(error.message), retiring: retiresRunnerAfterTurn)
            endTurn()
        default: break
        }
    }

    /// Retires the runner when asked to, then reports the turn's end, in a task of its own.
    ///
    /// **Its own task because the caller may already be cancelled, or about to be.** A result
    /// arrives on `eventTask`, and `retireRunner` cancels `eventTask`: everything after it here
    /// used to run in a cancelled task. `onTurnEnded` is where the queue tells runbloom.app the
    /// turn is over, and AsyncHTTPClient aborts a request made from a cancelled task, so on a
    /// machine that retires after every turn nearly every turn stayed `running` on runbloom.app
    /// until the workspace was archived, and the wait for the process to exit spun rather than
    /// slept because `Task.sleep` returns at once when cancelled. The same holds for the drain
    /// task that `refreshState` runs in, which a pause cancels. The task is awaited, so the turn
    /// is still busy until the end has been reported, as before.
    ///
    /// Retiring stays ahead of reporting, as `personBoundLaunchContextAndRetirement` holds: the
    /// process holding the turn's grants is gone before runbloom.app hears the turn is over.
    private func closeTurn(_ ending: RemoteTurnEnd?, retiring: Bool) async {
        await Task {
            if retiring { await retireRunner() }
            if let ending { await onTurnEnded(ending) }
        }.value
    }

    /// Runs the turn again on a fresh process when its `--resume` found no conversation, once, and
    /// answers whether it did.
    ///
    /// **A replaced machine never answered in a chat it had already spoken in.** The row carries
    /// the conversation id and the machine's disk no longer has the conversation, so the CLI failed
    /// before its first request and the failure paused the queue. The runner has already let go of
    /// the id and written the note by the time this event arrives (see `ConversationNotResumed`),
    /// so a new process from the row starts a new conversation, and the person's message goes to
    /// it rather than being handed back as an error they have to send again.
    ///
    /// A new process rather than a second launch inside the old runner, because a machine's
    /// launch boundary is deliberately single use: `ServeCommand` binds one person's grant to one
    /// process, and a second spawn through the same runner gets `/usr/bin/false`. Going through
    /// `make` again reserves a new boundary the ordinary way.
    ///
    /// In a task of its own for the reason `closeTurn` gives: this runs on `eventTask`, which
    /// retiring the old runner cancels.
    private func restartWithoutResume() async -> Bool {
        guard isBusy, !claimedEnd, !wasStopped, !restartedTurn, !isClosed,
              let delivery = turnDelivery, let launch else { return false }
        restartedTurn = true
        return await Task { await self.relaunch(delivery, on: launch) }.value
    }

    private func relaunch(_ delivery: Delivery, on launch: Launch) async -> Bool {
        prepareGeneration += 1
        let relaunching = prepareGeneration
        await retireRunner()
        // A stop or a shutdown during the retirement wins, and the turn ends as it would have.
        guard !isClosed, !wasStopped, relaunching == prepareGeneration else { return false }
        let fresh: any SessionRunner
        do {
            fresh = try await make(launch.environment, launch.context)
        } catch {
            return false
        }
        // Only Claude Code reports this failure, so only its runner is ever asked to take the
        // turn again, and it is the one that can do so without recording it twice.
        guard !isClosed, !wasStopped, relaunching == prepareGeneration, runner == nil,
              let claude = fresh as? AgentRunner else {
            await retire(fresh)
            return false
        }
        install(fresh, as: launch)
        do {
            try await claude.resendDelivery(delivery)
        } catch {
            return false
        }
        return true
    }

    private func endTurn() {
        isBusy = false
        busySince = nil
        let onIdle = onIdle
        Task { await onIdle() }
    }

    /// One report per turn, whichever of a result, an error or a failed send arrives first.
    private func claimEnd() -> Bool {
        guard !claimedEnd else { return false }
        claimedEnd = true
        return true
    }

    func stop() {
        // Keep the turn reserved until its terminal event. A late stop must not cancel a new turn.
        guard isBusy else { return }
        // Marked even with no runner to signal, which is a turn between its lost conversation's
        // process and the fresh one: `relaunch` reads this and ends the turn as stopped rather
        // than starting it again under somebody who asked it to stop.
        wasStopped = true
        runner?.cancelNow()
    }

    /// Waits for a stopped turn to come to rest, and ends it by force if it does not.
    ///
    /// **A stop does not always produce an event.** Claude Code on SIGINT marks the session
    /// cancelled in the store and sends no result, and until something called `refreshState` the
    /// turn stayed busy: the machine held itself awake all night and runbloom.app kept the turn
    /// open against the team. Only the queue's drain called it, and a stop pauses the queue first.
    /// So whoever stops also settles, here, and a runner that neither reports nor records within
    /// `limit` is retired and its turn ended as stopped.
    func settleStop(store: Store, sessionID: SessionID, limit: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while isBusy, wasStopped, ContinuousClock.now < deadline {
            try? await refreshState(store: store, sessionID: sessionID)
            guard isBusy else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard isBusy, wasStopped else { return }
        await retireRunner()
        guard isBusy else { return }
        if claimEnd() { await closeTurn(.stopped(stopReason ?? ""), retiring: false) }
        endTurn()
    }

    /// Releases a turn whose runner went quiet after a stop.
    ///
    /// A stored idle or failed row can beat its terminal event to this actor, and releasing the
    /// turn then would let a queued send start before that old event arrives. Only an explicit
    /// stop has a backend that may finish without a result event (Claude Code on SIGTERM).
    func refreshState(store: Store, sessionID: SessionID) async throws {
        guard isBusy, !isSending else { return }
        let observedGeneration = generation
        let session = try await store.session(id: sessionID)
        guard isBusy, !isSending, generation == observedGeneration else { return }
        if let session, session.state == .cancelled, wasStopped {
            streamingText = ""
            let ended = claimEnd()
            await closeTurn(ended ? .stopped(stopReason ?? "") : nil, retiring: retiresRunnerAfterTurn)
            endTurn()
        }
    }

    /// The first answer wins. A second, from anybody, is told the question was already answered.
    func answer(requestID: String, decision: PermissionDecision, store: Store, sessionID: SessionID) async throws {
        guard !isClosed, !answering.contains(requestID) else {
            throw RemoteFailure(.alreadyAnswered, "This question has already been answered.")
        }
        answering.insert(requestID)
        defer { answering.remove(requestID) }
        let pending = try await store.pendingPermissionAsks(sessionID: sessionID)
        guard let question = pending.first(where: { $0.requestID == requestID }), !isClosed, let runner else {
            throw RemoteFailure(.alreadyAnswered, "This question is no longer waiting for an answer.")
        }
        if case .approvePlan(let mode) = decision {
            guard question.ask.isPlanApproval, PlanApproval.modes.contains(mode) else {
                throw RemoteFailure(.invalidValue, "This question cannot approve implementation in that mode.")
            }
        }
        await runner.answer(requestID: requestID, decision: decision)
    }

    /// Stops the process when it holds personal credentials `superseded` says must go, ending a
    /// running turn with `reason` first. Answers whether a turn was running. The next turn launches
    /// a fresh process on whatever key runbloom.app then hands out.
    func retirePersonal(reason: String, where superseded: @Sendable (Set<String>) -> Bool) async -> Bool {
        guard runner != nil, !personalMarks.isEmpty, superseded(personalMarks) else { return false }
        let wasBusy = isBusy
        if wasBusy {
            stopReason = reason
            stop()
            let deadline = ContinuousClock.now.advanced(by: runnerExitGrace)
            while isBusy, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        await retireRunner()
        // The process is gone whether or not its last event made it here, so the turn is over.
        if isBusy {
            if claimEnd() { await closeTurn(.stopped(reason), retiring: false) }
            endTurn()
        }
        return wasBusy
    }

    private func retireRunner() async {
        guard let current = runner else { return }
        eventTask?.cancel()
        eventTask = nil
        runner = nil
        launchIdentity = nil
        personalMarks = []
        current.terminateNow()
        let deadline = ContinuousClock.now.advanced(by: runnerExitGrace)
        while await current.isProcessAlive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// A factory may finish after its launch was superseded. It never becomes actor state, but it
    /// still owns a process and must receive the same bounded termination as an installed runner.
    private func retire(_ fresh: any SessionRunner) async {
        fresh.terminateNow()
        let deadline = ContinuousClock.now.advanced(by: runnerExitGrace)
        while await fresh.isProcessAlive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func shutdown() async {
        isClosed = true
        prepareGeneration += 1
        // The runner escalates to SIGKILL on its own budget. Keep the server alive long enough for
        // that to run rather than orphaning a CLI that ignored SIGTERM, and bounded, so a runner
        // that never exits cannot hold shutdown for ever.
        await retireRunner()
    }

    deinit {
        runner?.terminateNow()
        eventTask?.cancel()
    }
}

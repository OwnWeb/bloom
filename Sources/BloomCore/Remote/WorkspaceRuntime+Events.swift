import BloomProtocol
import Foundation

// What the runtime tells everyone with the workspace open, and the calls from outside that change
// what it may do: a limit lifting, a limit being hit, somebody's access being revoked.
extension WorkspaceRuntime {
    /// Opens an event stream for one person.
    ///
    /// **State first, then history, then live, with nothing lost at either seam.** The live
    /// subscription is taken before anything is read, so an event published while the snapshot is
    /// being assembled waits in its buffer rather than being missed; the rows replayed after the
    /// client's cursor are then sent, and a live `message` at or below the last replayed cursor is
    /// skipped as the duplicate it is.
    public func openEvents(for caller: RemoteCaller, after cursor: Int64?, client: String? = nil) async throws -> AsyncStream<WorkspaceEvent> {
        guard !isClosed else { throw RemoteFailure.shuttingDown }
        if let author = caller.author { presence.noteName(author) }
        let subscription = await events.subscribe(userID: caller.author?.userID, client: client)
        do {
            return try await openEvents(subscription, after: cursor)
        } catch {
            // Or the subscriber stays counted: presence shows the person and the lease never
            // takes its cut for a stream nobody has.
            await events.unsubscribe(subscription.id)
            throw error
        }
    }

    private func openEvents(_ subscription: RemoteEventHub.Subscription, after cursor: Int64?) async throws -> AsyncStream<WorkspaceEvent> {
        // Where the replay stops and the live stream takes over, read before either starts so a row
        // written in between is sent once by the live stream rather than twice or not at all. And
        // before the questions below, not after them: a question is filed before the row that asks
        // it, so the question behind any row at or under this mark is already in the read that
        // follows. Reading the mark last let a row asked in between replay ahead of its question
        // and reach the client as one already answered. See `storeChanged`.
        let highWater = try await store.latestMessageID(workspaceID: workspaceID)
        var opening: [WorkspaceEvent] = []
        let workspace = try await workspace()
        opening.append(.workspace(workspace.record(setup: setupRecord(workspace), reporting: reporting, services: services)))
        opening.append(.setup(setupRecord(workspace)))
        for id in try await chatIDs() {
            let session = try await storedSession(id)
            opening.append(.chat(session.record(lastSeq: try await store.nextSeq(sessionID: id) - 1)))
            opening.append(.queue(try await queue().record(id)))
            opening.append(.questions(chatID: id.rawValue, questions: try await store.pendingPermissionAsks(sessionID: id).map(\.record)))
            if let text = await sessions[id]?.streamingText, !text.isEmpty {
                opening.append(.stream(chatID: id.rawValue, text: text, snapshot: true))
            }
        }
        opening.append(.presence(presence.records(knownAs: await memberLabels())))
        let from = cursor ?? highWater
        let initial = opening
        let live = subscription.events
        let store = store, workspaceID = workspaceID
        // Bounded like the hub's own buffer, above the opening events. Unbounded, this copy drained
        // the hub's buffer as fast as events came, so its overflow never fired and a client that
        // stopped reading grew the machine's memory instead of being disconnected.
        let (stream, continuation) = AsyncStream.makeStream(
            of: WorkspaceEvent.self, bufferingPolicy: .bufferingOldest(initial.count + RemoteEventHub.defaultBufferLimit)
        )
        let task = Task {
            for event in initial { continuation.yield(event) }
            // **The backlog is read a page at a time and yielded as it is read.** It used to be
            // collected into one array before the stream answered, so a client reconnecting to a
            // long conversation had every row it had missed in memory at once, payloads and all,
            // on a machine sized for one workspace. Whatever the client cannot keep up with is
            // held by the buffer above, and a client slower than the buffer is disconnected, which
            // is what the cursor is for.
            var replayed = from
            while replayed < highWater, !Task.isCancelled {
                guard let page = try? await store.messages(workspaceID: workspaceID, afterID: replayed, limit: 200),
                      let last = page.last else { break }
                for message in page where message.id <= highWater {
                    if case .dropped = continuation.yield(.message(message.record)) { break }
                }
                replayed = last.id
            }
            for await event in live {
                if let eventCursor = event.cursor, eventCursor <= highWater { continue }
                if case .dropped = continuation.yield(event) { break }
            }
            continuation.finish()
        }
        let hub = events, subscriptionID = subscription.id
        continuation.onTermination = { _ in
            task.cancel()
            Task { await hub.unsubscribe(subscriptionID) }
        }
        return stream
    }

    /// Human input that does not arrive as a command: a keystroke in a terminal, a navigation in
    /// the preview. It renews the presence lease the same way a prompt does.
    public func noteHumanInput(from author: MessageAuthor) async {
        presence.noteInput(author, at: Date())
        await report(.humanInput)
    }

    public var lastHumanInputAt: Date? { presence.lastHumanInputAt }

    func connectionsChanged() async {
        if presence.setConnected(await events.connectedUserIDs) {
            await events.publish(.presence(presence.records(knownAs: await memberLabels())))
        }
        await report(.connectionsChanged(open: await events.count))
    }

    func queueChanged(_ id: SessionID) async {
        guard let record = try? await queue().record(id) else { return }
        await events.publish(.queue(record))
    }

    func streamed(_ id: SessionID, text: String, reset: Bool) async {
        await events.publish(.stream(chatID: id.rawValue, text: text, snapshot: reset))
    }

    /// Reads what a commit changed and publishes what a client has not been told yet.
    ///
    /// Only reads, never writes, for the reason `StoreChangeHub` gives: a handler that writes back
    /// into the store it listens to wakes itself for ever.
    ///
    /// **Questions go out before the rows that ask them.** A client reads a question row whose
    /// request id is not in the chat's `questions` as one that has been answered, and this used to
    /// publish every new row first and the state after it, so an AskUserQuestion reached the Mac as
    /// "Answered." while it was still waiting on the machine. The runner files the question before
    /// it writes the row, so questions read after a page cannot miss one the page asks, which is
    /// why they are read after it and published before it rather than read up front: a question
    /// filed between an early read and the page would have been missed again.
    func storeChanged(_ domains: Set<StoreDomain>) async {
        do {
            if domains.contains(.messages) {
                while true {
                    let page = try await store.messages(workspaceID: workspaceID, afterID: publishedCursor, limit: 500)
                    if domains.contains(.permissionAsks) || page.contains(where: { $0.kind == .permissionAsk }) {
                        try await refreshPublishedQuestions()
                    }
                    for message in page { await events.publish(.message(message.record)) }
                    guard let last = page.last else { break }
                    publishedCursor = last.id
                    if page.count < 500 { break }
                }
            }
            if !domains.isDisjoint(with: [.sessions, .permissionAsks, .workspaces]) {
                try await refreshPublishedState(publishing: true)
            }
        } catch {
            // A read that failed is retried by the next commit; a client missing one state event
            // in the meantime is corrected by that one, because state events are sent whole.
        }
    }

    /// Compares chats, questions and setup with what was last published, and publishes changes.
    func refreshPublishedState(publishing: Bool) async throws {
        var seen: Set<SessionID> = []
        for session in try await store.sessions(workspaceID: workspaceID) where session.archivedAt == nil {
            seen.insert(session.id)
            let chat = session.record(lastSeq: try await store.nextSeq(sessionID: session.id) - 1)
            if publishedChats[session.id] != chat {
                publishedChats[session.id] = chat
                if publishing { await events.publish(.chat(chat)) }
            }
            try await refreshPublishedQuestions(session.id, publishing: publishing)
        }
        for id in publishedChats.keys where !seen.contains(id) {
            // Claim the removal before the first suspension. Two refreshes can overlap while one
            // waits on the Store actor; leaving the cache entry until afterwards let both publish
            // the same closing chat event.
            publishedChats.removeValue(forKey: id)
            publishedQuestions.removeValue(forKey: id)
            guard publishing,
                  let captured = try await store.session(id: id),
                  captured.archivedAt != nil else { continue }
            await beforeClosedChatPublication?(id)
            let lastSeq = try await store.nextSeq(sessionID: id) - 1
            // `captured` may be stale after either suspension above. Reopening clears the stamp
            // and publishes the open record while this refresh is away; publishing `captured`
            // afterwards would put every client back into the closed state while Store is open.
            // This final read and the call to EventHub have no WorkspaceRuntime suspension between
            // them: the event is enqueued before another runtime command can change the row again.
            guard let current = try await store.session(id: id), current.archivedAt != nil else { continue }
            await events.publish(.chat(current.record(lastSeq: lastSeq)))
        }
        guard let workspace = try await store.workspace(id: workspaceID) else { return }
        let record = workspace.record(setup: setupRecord(workspace), reporting: reporting, services: services)
        if publishedWorkspace != record {
            let first = publishedWorkspace == nil
            publishedWorkspace = record
            if publishing {
                await events.publish(.workspace(record))
                if !first { await report(.workspaceChanged) }
            }
        }
        let setup = setupRecord(workspace)
        if publishedSetup != setup {
            publishedSetup = setup
            if publishing { await events.publish(.setup(setup)) }
        }
        // The setup log only ever grows during a run, so what is new is its tail. A log that
        // shrank was a new run starting, and is sent from its beginning.
        let log = workspace.setupLog
        if log.utf8.count != publishedSetupLogLength {
            let bytes = Array(log.utf8)
            let start = bytes.count > publishedSetupLogLength ? publishedSetupLogLength : 0
            publishedSetupLogLength = bytes.count
            if publishing, start < bytes.count {
                await events.publish(.setupOutput(text: String(decoding: bytes[start...], as: UTF8.self)))
            }
        }
    }

    /// Publishes the questions of every open chat that changed since they were last published.
    /// See `storeChanged` for why this runs ahead of the rest of the state.
    func refreshPublishedQuestions() async throws {
        for session in try await store.sessions(workspaceID: workspaceID) where session.archivedAt == nil {
            try await refreshPublishedQuestions(session.id, publishing: true)
        }
    }

    private func refreshPublishedQuestions(_ id: SessionID, publishing: Bool) async throws {
        let questions = try await store.pendingPermissionAsks(sessionID: id).map(\.record)
        if publishedQuestions[id] ?? [] != questions {
            publishedQuestions[id] = questions
            if publishing { await events.publish(.questions(chatID: id.rawValue, questions: questions)) }
        }
    }

    /// Installs the deterministic pause used by the close/reopen overlap regression.
    func setBeforeClosedChatPublication(_ pause: (@Sendable (SessionID) async -> Void)?) {
        beforeClosedChatPublication = pause
    }

    // MARK: - Calls from runbloom.app

    /// A limit lifted: every prompt a limit blocked is tried again.
    public func limitsCleared() async {
        await queue().retryBlocked()
    }

    /// A limit was reached while the machine is awake: running turns stop the way Stop stops them,
    /// and every waiting prompt is marked with the limit rather than sent.
    ///
    /// `inactive` is runbloom.app telling a machine that stayed awake with nobody working to go to
    /// sleep: its turns stop, but nothing is blocked, because no limit was reached and nothing has
    /// to be cleared before the next prompt may go.
    public func stopForLimit(_ block: DeliveryBlock) async {
        if block.limit == "inactive" {
            for id in sessions.keys { await stopAndSettle(id) }
            return
        }
        for id in (try? await chatIDs()) ?? [] {
            if let pending = try? await store.pendingDeliveries(sessionID: id) {
                for delivery in pending where delivery.state == .pending {
                    try? await store.setDeliveryBlock(id: delivery.id, block)
                }
            }
            await stopAndSettle(id)
            await queueChanged(id)
        }
    }

    /// Somebody lost access: their streams close at once rather than when their token runs out,
    /// their queued prompts go, a turn of theirs that is running stops, and the shells they opened
    /// end, since each of those carries their key.
    public func revoke(userID: String) async {
        await events.close(with: .closing(WireError(.unauthenticated, "Your access to this Bloom Cloud workspace was removed.")),
                           where: { $0 == userID })
        guard !isClosed else { return }
        let chats = (try? await chatIDs()) ?? []
        let stopping = await queue().revoke(userID: userID, sessions: chats)
        for id in stopping { await stopAndSettle(id) }
        try? await terminalService?.closeAll(ownedBy: userID)
    }

    /// Tells everyone the machine is about to sleep and closes their streams. Sent before the
    /// machine lets go of its last hold, because a paused machine sends nothing.
    public func announceSleep() async {
        await events.close(with: .sleeping)
    }

    // MARK: - Setup, as the machine's setup runner reports it

    public func setupStepStarted(_ step: String) async {
        if setupStartedAt == nil || setupFinishedAt != nil {
            setupStartedAt = Date()
            setupFinishedAt = nil
        }
        let starting = !holdsPromptsForSetup
        setupStep = step
        holdsPromptsForSetup = true
        try? await refreshPublishedState(publishing: true)
        await report(starting ? .setupStarted(step: step) : .setupStep(step))
    }

    /// The machine has, or has not, been able to reach runbloom.app. Publishing it is the whole
    /// point: an outage that nobody can see is the one failure here with no symptom, because a
    /// prompt that cannot start pauses its chat with a sentence and a report that cannot be sent
    /// says nothing at all.
    public func reportingChanged(_ record: ReportingRecord?) async {
        guard record != reporting else { return }
        reporting = record
        try? await refreshPublishedState(publishing: true)
    }

    /// What the setup runner found under the step it is running, from the machine's own watchdog.
    ///
    /// **Published when the verdict changes rather than on every look**, because the looks are
    /// every thirty seconds for the length of a setup and the verdict changes a handful of times.
    /// A machine whose step has just stopped having anything alive in it is the one case anybody is
    /// waiting for, and that is a change.
    public func setupLivenessChanged(_ liveness: RemoteSummary.Setup.Liveness?) async {
        guard liveness?.verdict != setupLiveness?.verdict else {
            setupLiveness = liveness
            return
        }
        setupLiveness = liveness
        try? await refreshPublishedState(publishing: true)
    }

    /// The machine's service supervisor, saying what it is running. Published so a client can draw
    /// a service that never started, which is otherwise a sentence nobody can reach.
    public func servicesChanged(_ services: [ServiceRecord]) async {
        guard services != self.services else { return }
        self.services = services
        try? await refreshPublishedState(publishing: true)
    }

    /// Setup finished, however it ended, and the prompts that waited for it may go: a failed setup
    /// is something the agent can read the log of and fix, which is what the Mac does too.
    public func setupFinished(succeeded: Bool = true) async {
        setupStep = nil
        // No step, no child, nothing to be alive: a stale verdict outliving its step would be read
        // as a fact about whatever ran next.
        setupLiveness = nil
        setupFinishedAt = Date()
        holdsPromptsForSetup = false
        lastSetupSucceeded = succeeded
        try? await refreshPublishedState(publishing: true)
        await report(.setupFinished(succeeded: succeeded))
        for id in (try? await chatIDs()) ?? [] { await queue().resume(id) }
    }
}

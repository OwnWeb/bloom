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
    public func openEvents(for caller: RemoteCaller, after cursor: Int64?) async throws -> AsyncStream<WorkspaceEvent> {
        guard !isClosed else { throw RemoteFailure.shuttingDown }
        if let author = caller.author { presence.noteName(author) }
        let subscription = await events.subscribe(userID: caller.author?.userID)
        var opening: [WorkspaceEvent] = []
        let workspace = try await workspace()
        opening.append(.workspace(workspace.record(setup: setupRecord(workspace))))
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
        opening.append(.presence(presence.records))
        var replayed = cursor ?? 0
        if cursor != nil {
            while true {
                let page = try await store.messages(workspaceID: workspaceID, afterID: replayed, limit: 500)
                opening += page.map { .message($0.record) }
                guard let last = page.last else { break }
                replayed = last.id
                if page.count < 500 { break }
            }
        } else {
            replayed = try await store.latestMessageID(workspaceID: workspaceID)
        }
        let highWater = replayed
        let initial = opening
        let live = subscription.events
        let (stream, continuation) = AsyncStream.makeStream(of: WorkspaceEvent.self)
        let task = Task {
            for event in initial { continuation.yield(event) }
            for await event in live {
                if let eventCursor = event.cursor, eventCursor <= highWater { continue }
                continuation.yield(event)
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
            await events.publish(.presence(presence.records))
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
    func storeChanged(_ domains: Set<StoreDomain>) async {
        do {
            if domains.contains(.messages) {
                while true {
                    let page = try await store.messages(workspaceID: workspaceID, afterID: publishedCursor, limit: 500)
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
            let questions = try await store.pendingPermissionAsks(sessionID: session.id).map(\.record)
            if publishedQuestions[session.id] ?? [] != questions {
                publishedQuestions[session.id] = questions
                if publishing { await events.publish(.questions(chatID: session.id.rawValue, questions: questions)) }
            }
        }
        for id in publishedChats.keys where !seen.contains(id) {
            if publishing, let session = try await store.session(id: id) {
                await events.publish(.chat(session.record(lastSeq: try await store.nextSeq(sessionID: id) - 1)))
            }
            publishedChats.removeValue(forKey: id)
            publishedQuestions.removeValue(forKey: id)
        }
        guard let workspace = try await store.workspace(id: workspaceID) else { return }
        let record = workspace.record(setup: setupRecord(workspace))
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
            for session in sessions.values { await session.stop() }
            return
        }
        for id in (try? await chatIDs()) ?? [] {
            if let pending = try? await store.pendingDeliveries(sessionID: id) {
                for delivery in pending where delivery.state == .pending {
                    try? await store.setDeliveryBlock(id: delivery.id, block)
                }
            }
            await sessions[id]?.stop()
            await queueChanged(id)
        }
    }

    /// Somebody lost access: their streams close at once rather than when their token runs out,
    /// their queued prompts go, a turn of theirs that is running stops, and the shells they opened
    /// end, since each of those carries their key.
    public func revoke(userID: String) async {
        await events.close(with: .closing(WireError(.unauthenticated, "Your access to this Cloud workspace was removed.")),
                           where: { $0 == userID })
        guard !isClosed else { return }
        let chats = (try? await chatIDs()) ?? []
        let stopping = await queue().revoke(userID: userID, sessions: chats)
        for id in stopping { await sessions[id]?.stop() }
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

    /// Setup finished, however it ended, and the prompts that waited for it may go: a failed setup
    /// is something the agent can read the log of and fix, which is what the Mac does too.
    public func setupFinished(succeeded: Bool = true) async {
        setupStep = nil
        setupFinishedAt = Date()
        holdsPromptsForSetup = false
        lastSetupSucceeded = succeeded
        try? await refreshPublishedState(publishing: true)
        await report(.setupFinished(succeeded: succeeded))
        for id in (try? await chatIDs()) ?? [] { await queue().resume(id) }
    }
}

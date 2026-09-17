import BloomProtocol
import Foundation

// The chats in a Cloud workspace: reading them, starting and closing them, what their composers
// are set to, sending, stopping and answering.
extension WorkspaceRuntime {
    static let transcriptPageLimit = 500

    func snapshot() async throws -> WorkspaceSnapshotRecord {
        let workspace = try await workspace()
        let cursor = try await store.latestMessageID(workspaceID: workspaceID)
        var chats: [ChatRecord] = []
        for session in try await store.sessions(workspaceID: workspaceID) where session.archivedAt == nil {
            chats.append(session.record(lastSeq: try await store.nextSeq(sessionID: session.id) - 1))
        }
        return WorkspaceSnapshotRecord(workspace: workspace.record(setup: setupRecord(workspace)), chats: chats,
                                       presence: presence.records, cursor: cursor)
    }

    func setupRecord(_ workspace: Workspace) -> SetupRecord {
        SetupRecord(state: workspace.setupState.rawValue, step: setupStep, startedAt: setupStartedAt, finishedAt: setupFinishedAt)
    }

    func transcript(_ chatID: String, afterSeq: Int, limit: Int?) async throws -> TranscriptRecord {
        let id = try chatID.sessionID
        let session = try await storedSession(id)
        guard afterSeq >= -1 else { throw RemoteFailure.invalid("A transcript page starts after a sequence number of -1 or more.") }
        let pageSize = min(max(limit ?? Self.transcriptPageLimit, 1), Self.transcriptPageLimit)
        var messages = try await store.messages(sessionID: id, afterSeq: afterSeq, limit: pageSize + 1)
        let hasMore = messages.count > pageSize
        if hasMore { messages.removeLast() }
        let live = sessions[id]
        try await live?.refreshState(store: store, sessionID: id)
        return TranscriptRecord(
            chat: session.record(lastSeq: try await store.nextSeq(sessionID: id) - 1),
            messages: messages.map(\.record), hasMore: hasMore,
            questions: try await store.pendingPermissionAsks(sessionID: id).map(\.record),
            busy: await live?.isBusy ?? false, streamingText: await live?.streamingText ?? "",
            queue: try await queue().record(id)
        )
    }

    func controls(for session: Session) async throws -> ComposerControls {
        ComposerControls(
            session: session,
            isFastMode: try await store.setting(ComposerControls.fastModeKey(sessionID: session.id)) == "1",
            outputStyle: try await store.setting(ComposerControls.outputStyleKey(sessionID: session.id)) ?? OutputStyle.defaultName,
            codexContextWindow: CodexContextWindow.normalised(try await store.setting(ComposerControls.contextWindowKey(sessionID: session.id))),
            codexFastMode: CodexSpeed.override(stored: try await store.setting(CodexSpeed.key(sessionID: session.id)))
        )
    }

    func composer(_ chatID: String) async throws -> ComposerRecord {
        let session = try await storedSession(try chatID.sessionID)
        let workspace = try await workspace()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ComposerRecord(
            chatID: chatID,
            controls: try await controls(for: session).record,
            availableAgents: await installedAgents().map(\.wireName),
            models: await models(workspace.path),
            commands: SlashCommandIndex.discover(home: home, project: workspace.path).map { SlashCommandRecord(name: $0.name, description: $0.detail) },
            outputStyles: OutputStyleIndex.discover(home: home, project: workspace.path).map(\.name)
        )
    }

    func requireInstalled(_ agent: AgentKind) async throws {
        guard await installedAgents().contains(agent) else {
            throw RemoteFailure(.agentUnavailable, "\(agent.label) is not installed on this machine. Choose another agent in the model menu.")
        }
    }

    func newChat(_ record: ComposerControlsRecord, as caller: RemoteCaller) async throws -> ChatRecord {
        let controls = try ComposerControls(record: record)
        try await requireInstalled(controls.agentKind)
        _ = try await workspace()
        let existing = try await store.sessions(workspaceID: workspaceID)
        let title = PaneNaming.nextTitle(base: PaneNaming.chat, taken: existing.map(\.title))
        let session = try await store.upsert(Session(
            workspaceID: workspaceID, title: title, model: controls.model, effort: controls.effort,
            agentKind: controls.agentKind, permissionMode: controls.permissionMode, interactionMode: controls.interactionMode
        ))
        try await store.saveComposerControls(controls, sessionID: session.id)
        return session.record(lastSeq: -1)
    }

    func renameChat(_ chatID: String, title: String) async throws {
        let id = try chatID.sessionID
        _ = try await storedSession(id)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 1_024 else { throw RemoteFailure.invalid("Enter a shorter conversation name.") }
        try await store.updateSessionPreferences(id: id, title: name)
    }

    /// Stops the chat's agent and files the chat away. Its transcript is kept.
    func closeChat(_ id: SessionID, notifyingParent: Bool) async throws {
        guard closingSessions.insert(id).inserted else { throw RemoteFailure(.busy, "This conversation is already being closed.") }
        defer { closingSessions.remove(id) }
        let session = try await storedSession(id)
        guard session.archivedAt == nil else { return }
        try await stop(id)
        await crewChatClosing(session, notifyingParent: notifyingParent)
        await sessions[id]?.shutdown()
        sessions.removeValue(forKey: id)
        _ = try await store.update(sessionID: id) { $0.archivedAt = Date() }
    }

    /// Last writer wins, and the event names who wrote it.
    ///
    /// A change of agent on a chat that has already spoken would strand its transcript half in one
    /// backend's vocabulary, so that is refused here and a client opens a new chat instead, which is
    /// what the Mac's picker does.
    func setComposer(_ chatID: String, controls record: ComposerControlsRecord, as caller: RemoteCaller) async throws {
        let id = try chatID.sessionID
        let controls = try ComposerControls(record: record)
        try await requireInstalled(controls.agentKind)
        let session = try await storedSession(id)
        if controls.agentKind != session.agentKind, try await store.messageCount(sessionID: id) > 0 {
            throw RemoteFailure.invalid("This conversation already has messages from \(session.agentKind.label). Open a new chat to use \(controls.agentKind.label).")
        }
        guard stopping[id] == nil else { throw RemoteFailure(.busy, "This conversation is being changed. Try again shortly.") }
        stopping[id] = 1
        defer { stopping.removeValue(forKey: id) }
        // Settings a process was launched with only take effect on a new process, so a running
        // turn has to end first and the idle process is let go.
        if let live = sessions[id] {
            try await live.refreshState(store: store, sessionID: id)
            guard await !live.isBusy else { throw RemoteFailure(.busy, "Stop the current turn before changing its settings.") }
            await live.shutdown()
            sessions.removeValue(forKey: id)
        }
        try await store.updateSessionPreferences(
            id: id, model: controls.model, effort: controls.effort, permissionMode: controls.permissionMode,
            interactionMode: controls.interactionMode, agentKind: controls.agentKind
        )
        try await store.saveComposerControls(controls, sessionID: id)
        await events.publish(.composer(chatID: chatID, controls: controls.record, changedBy: caller.author?.record))
    }

    func send(_ chatID: String, text: String, as caller: RemoteCaller) async throws -> DeliveryID {
        let id = try chatID.sessionID
        guard stopping[id] == nil else { throw RemoteFailure(.busy, "This conversation is being stopped.") }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw RemoteFailure.invalid("Type a message before sending.") }
        guard body.utf8.count <= 1_048_576 else { throw RemoteFailure(.tooLarge, "This message is larger than 1 MB.") }
        let session = try await storedSession(id)
        guard session.archivedAt == nil else { throw RemoteFailure(.unavailable, "This conversation is closed.") }
        try await requireInstalled(session.agentKind)
        _ = try await workspace()
        return try await queue().enqueue(body, session: session, caller: caller)
    }

    /// Pauses the chat's queue and stops its turn. Anybody who can prompt can stop.
    func stop(_ id: SessionID) async throws {
        stopping[id, default: 0] += 1
        defer {
            stopping[id, default: 1] -= 1
            if stopping[id] == 0 { stopping.removeValue(forKey: id) }
        }
        _ = try await storedSession(id)
        try await queue().pause(id)
        await stopAndSettle(id)
    }

    /// Stops a chat's turn and makes sure it comes to rest. See `RemoteSession.settleStop`.
    func stopAndSettle(_ id: SessionID) async {
        guard let session = sessions[id] else { return }
        await session.stop()
        let store = store
        Task { await session.settleStop(store: store, sessionID: id) }
    }

    func answerQuestion(_ chatID: String, requestID: String, answer: Answer) async throws {
        let id = try chatID.sessionID
        guard let live = sessions[id] else {
            throw RemoteFailure(.alreadyAnswered, "This question is no longer waiting for an answer.")
        }
        let decision = try answer.decision
        if case .deny(_, true) = decision { try await queue().pause(id) }
        try await live.answer(requestID: requestID, decision: decision, store: store, sessionID: id)
    }
}

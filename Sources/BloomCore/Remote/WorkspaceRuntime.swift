import BloomProtocol
import Foundation

/// The one Cloud workspace a machine holds: its chats, their agents and queue, its worktree, and
/// everyone with it open.
///
/// **The single owner of the store and of every agent process on the machine.** Clients send
/// commands and read events; none of them opens the database or launches a runner, and none of
/// them owns anything that stops when they disconnect. This is #163's `ServerRuntime` cut down to
/// one workspace: the catalogue, projects, creation, storage, skills and maintenance are gone,
/// because a machine is created for one workspace and deleted with it.
///
/// **A mutation runs once, whatever the network does.** Every command carries its client's id,
/// and a mutation is journalled before it runs and its reply after. A retry of a command that
/// already ran is answered from the journal; a retry of one the server stopped in the middle of
/// is answered `outcome_unknown` rather than run again, because a prompt sent twice is worse
/// than a person being asked to look. A machine pausing mid-request is the ordinary case of this
/// here, not a rare one.
///
/// The operations themselves live in the extensions beside this file, by subject.
public actor WorkspaceRuntime {
    public typealias AgentDiscovery = @Sendable () async -> [AgentKind]
    public typealias ModelDiscovery = @Sendable (_ cwd: String) async -> [ModelRecord]

    let store: Store
    public nonisolated let workspaceID: WorkspaceID
    let gate: any RemoteTurnGate
    let makeRunner: RemoteRunnerFactory.Make
    let installedAgents: AgentDiscovery
    let models: ModelDiscovery
    let runnerExitGrace: Duration
    public nonisolated let events: RemoteEventHub
    let admissions = RemoteAdmissions()
    let reviewCache = RemoteReviewCache()
    var terminalService: RemoteTerminals?

    var sessions: [SessionID: RemoteSession] = [:]
    var creating: [SessionID: Task<RemoteSession, Error>] = [:]
    var commands: [String: Task<CommandReply, Never>] = [:]
    var stopping: [SessionID: Int] = [:]
    var closingSessions: Set<SessionID> = []
    var promptQueue: RemotePromptQueue?
    var presence = RemotePresence()
    var observation: Task<Void, Never>?
    /// What the event stream has published up to, so a message is announced once.
    var publishedCursor: Int64 = 0
    var publishedChats: [SessionID: ChatRecord] = [:]
    var publishedQuestions: [SessionID: [QuestionRecord]] = [:]
    var publishedSetup: SetupRecord?
    var publishedSetupLogLength = 0
    /// Which setup step is running, for the setup record. Set by the machine's setup runner.
    var setupStep: String?
    var setupStartedAt: Date?
    var setupFinishedAt: Date?
    /// Whether the workspace's prompts must wait: setup has not finished yet.
    var holdsPromptsForSetup = false
    var archivePreviews: [String: (preview: ArchivePreviewRecord, createdAt: Date)] = [:]
    var isClosed = false
    var shutdownTask: Task<Void, Never>?

    public init(
        store: Store,
        workspaceID: WorkspaceID,
        gate: any RemoteTurnGate = UngatedTurns(),
        makeRunner: @escaping RemoteRunnerFactory.Make = RemoteRunnerFactory.live,
        installedAgents: @escaping AgentDiscovery = WorkspaceRuntime.installedAgents,
        models: @escaping ModelDiscovery = WorkspaceRuntime.liveModels,
        runnerExitGrace: Duration = .seconds(6)
    ) {
        self.store = store
        self.workspaceID = workspaceID
        self.gate = gate
        self.makeRunner = makeRunner
        self.installedAgents = installedAgents
        self.models = models
        self.runnerExitGrace = runnerExitGrace
        // Weakly back to the runtime, because the hub is the runtime's and a strong reference
        // from its closure would keep both alive for ever.
        let box = WeakRuntime()
        events = RemoteEventHub { await box.runtime?.connectionsChanged() }
        box.runtime = self
    }

    /// Picks up where a previous run of the server left off and starts publishing events.
    public func start() async throws {
        guard observation == nil else { return }
        publishedCursor = try await store.latestMessageID(workspaceID: workspaceID)
        try await refreshPublishedState(publishing: false)
        try await queue().restore(sessions: chatIDs())
        observation = Task { [weak self, store] in
            for await domains in store.changes(of: [.messages, .sessions, .permissionAsks, .workspaces]) {
                guard !Task.isCancelled, let self else { return }
                await self.storeChanged(domains)
            }
        }
    }

    // MARK: - Commands

    public func respond(to request: CommandRequest, as caller: RemoteCaller) async -> CommandReply {
        guard request.protocol == WorkspaceProtocol.name, request.version == WorkspaceProtocol.version else {
            return CommandReply(commandID: request.commandID, error: WireError(.unsupportedVersion,
                "This Cloud workspace speaks \(WorkspaceProtocol.name) version \(WorkspaceProtocol.version). Update Bloom."))
        }
        guard !request.commandID.isEmpty, request.commandID.utf8.count <= 128 else {
            return CommandReply(commandID: request.commandID, error: WireError(.invalidRequest, "A command needs an id of up to 128 characters."))
        }
        do {
            try caller.requires(request.operation.ability)
        } catch {
            return CommandReply(commandID: request.commandID, error: RemoteFailure.wire(error))
        }
        guard !isClosed else { return CommandReply(commandID: request.commandID, error: RemoteFailure.shuttingDown.wire) }
        if request.operation.isHumanInput, let author = caller.author { presence.noteInput(author, at: Date()) }
        guard request.operation.mutates else { return await execute(request, as: caller) }
        if let task = commands[request.commandID] {
            _ = await task.value
            return await recorded(request)
        }
        // Registered before the first suspension, so two retries arriving together share one run.
        let task = Task { await self.performOnce(request, as: caller) }
        commands[request.commandID] = task
        let reply = await task.value
        commands.removeValue(forKey: request.commandID)
        return reply
    }

    private static func journalKey(_ commandID: String) -> String { "remote.command." + commandID }

    private struct JournalEntry: Codable {
        var request: CommandRequest
        var reply: CommandReply?
        var recordedAt: Date

        enum CodingKeys: String, CodingKey {
            case request, reply
            case recordedAt = "recorded_at"
        }
    }

    private func performOnce(_ request: CommandRequest, as caller: RemoteCaller) async -> CommandReply {
        do {
            if try await store.setting(Self.journalKey(request.commandID)) != nil { return await recorded(request) }
            try await journal(JournalEntry(request: request, reply: nil, recordedAt: Date()))
            let reply = await execute(request, as: caller)
            try await journal(JournalEntry(request: request, reply: reply, recordedAt: Date()))
            return reply
        } catch {
            return CommandReply(commandID: request.commandID, error: RemoteFailure.wire(error))
        }
    }

    private func recorded(_ request: CommandRequest) async -> CommandReply {
        do {
            guard let text = try await store.setting(Self.journalKey(request.commandID)) else {
                throw RemoteFailure(.outcomeUnknown, "The outcome of this command is unknown. Refresh before trying again.")
            }
            let entry = try WireJSON.decode(JournalEntry.self, from: Data(text.utf8))
            guard entry.request == request else {
                throw RemoteFailure(.commandIDReused, "A command id cannot be reused for a different operation.")
            }
            return entry.reply ?? CommandReply(commandID: request.commandID, error: WireError(.outcomeUnknown,
                "The server stopped while handling this command. Check the workspace before sending it again."))
        } catch {
            return CommandReply(commandID: request.commandID, error: RemoteFailure.wire(error))
        }
    }

    private func journal(_ entry: JournalEntry) async throws {
        let data = try WireJSON.encode(entry)
        try await store.setSetting(Self.journalKey(entry.request.commandID), String(decoding: data, as: UTF8.self))
    }

    private func execute(_ request: CommandRequest, as caller: RemoteCaller) async -> CommandReply {
        do {
            let permit = request.operation.mutates && !request.operation.isArchive ? try admissions.admit() : nil
            defer { permit?.release() }
            return CommandReply(commandID: request.commandID, result: try await perform(request.operation, as: caller))
        } catch {
            return CommandReply(commandID: request.commandID, error: RemoteFailure.wire(error))
        }
    }

    private func perform(_ operation: WorkspaceOperation, as caller: RemoteCaller) async throws -> OperationResult {
        guard !isClosed else { throw RemoteFailure.shuttingDown }
        switch operation {
        case .workspace: return .workspace(try await snapshot())
        case .transcript(let chatID, let afterSeq, let limit): return .transcript(try await transcript(chatID, afterSeq: afterSeq, limit: limit))
        case .composer(let chatID): return .composer(try await composer(chatID))
        case .newChat(let controls): return .chat(try await newChat(controls, as: caller))
        case .renameChat(let chatID, let title): try await renameChat(chatID, title: title); return .accepted
        case .closeChat(let chatID): try await closeChat(try chatID.sessionID, notifyingParent: true); return .accepted
        case .markRead(let chatID, let seq):
            _ = try await storedSession(try chatID.sessionID)
            try await store.updateLastReadSeq(sessionID: try chatID.sessionID, seq: seq)
            return .accepted
        case .setComposer(let chatID, let controls): try await setComposer(chatID, controls: controls, as: caller); return .accepted
        case .send(let chatID, let text): return .queued(promptID: try await send(chatID, text: text, as: caller).rawValue)
        case .cancelQueued(let chatID, let promptID):
            try await queue().cancel(DeliveryID(promptID), sessionID: try chatID.sessionID)
            return .accepted
        case .stop(let chatID): try await stop(try chatID.sessionID); return .accepted
        case .answer(let chatID, let requestID, let answer): try await answerQuestion(chatID, requestID: requestID, answer: answer); return .accepted
        case .setupOutput, .files, .file, .download, .reviewSnapshot, .reviewPatch, .runScripts, .notes, .pullRequest,
             .archivePreview, .writeFile, .uploadFile, .commit, .push, .createPullRequest, .saveNotes, .renameWorkspace,
             .runSetup, .runScript, .closeTerminal, .archive:
            return try await performOnWorktree(operation, as: caller)
        }
    }

    // MARK: - Lifecycle

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        isClosed = true
        admissions.stop()
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        await task.value
    }

    private func finishShutdown() async {
        observation?.cancel()
        let running = Array(commands.values)
        for command in running { command.cancel() }
        await promptQueue?.shutdown()
        await reviewCache.shutdown()
        await terminalService?.shutdown()
        let live = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in live { group.addTask { await session.shutdown() } }
        }
        for command in running { _ = await command.value }
        sessions.removeAll()
        await events.close(with: .closing(WireError(.unavailable, "The server is shutting down.")))
    }

    // MARK: - Shared lookups

    func workspace() async throws -> Workspace {
        guard let workspace = try await store.workspace(id: workspaceID), workspace.state == .active else {
            throw RemoteFailure(.workspaceChanging, "This Cloud workspace is no longer available.")
        }
        return workspace
    }

    func repo(for workspace: Workspace) async throws -> Repo {
        guard let repo = try await store.repo(id: workspace.repoID) else {
            throw RemoteFailure(.internal, "This Cloud workspace's repository is missing on the machine.")
        }
        return repo
    }

    func storedSession(_ id: SessionID) async throws -> Session {
        guard let session = try await store.session(id: id), session.workspaceID == workspaceID else {
            throw RemoteFailure.notFound("This conversation no longer exists.")
        }
        return session
    }

    func chatIDs() async throws -> [SessionID] {
        try await store.sessions(workspaceID: workspaceID).filter { $0.archivedAt == nil }.map(\.id)
    }

    func queue() -> RemotePromptQueue {
        if let promptQueue { return promptQueue }
        let queue = RemotePromptQueue(store: store, gate: gate, load: { [weak self] id in
            guard let self else { throw RemoteFailure.shuttingDown }
            return try await self.liveSession(id)
        }, held: { [weak self] _ in
            await self?.holdsPromptsForSetup ?? false
        }, changed: { [weak self] id in
            await self?.queueChanged(id)
        }, settled: { [weak self] id, ending in
            await self?.turnSettled(id, ending: ending)
        })
        promptQueue = queue
        return queue
    }

    func liveSession(_ id: SessionID) async throws -> RemoteSession {
        guard !isClosed, !closingSessions.contains(id) else {
            throw RemoteFailure(.unavailable, "This conversation is closed. Open a new chat before sending a message.")
        }
        if let session = sessions[id] { return session }
        if let task = creating[id] { return try await task.value }
        let task = Task { [self] () throws -> RemoteSession in
            let session = try await self.storedSession(id)
            guard session.archivedAt == nil else { throw RemoteFailure(.unavailable, "This conversation is closed.") }
            let workspace = try await self.workspace()
            let store = self.store, make = self.makeRunner
            return RemoteSession(
                runnerExitGrace: self.runnerExitGrace,
                make: { environment in make(session, workspace.path, store, environment) },
                onStream: { [weak self] text, reset in await self?.streamed(id, text: text, reset: reset) },
                onTurnEnded: { [weak self] ending in await self?.queue().turnEnded(id, ending: ending) }
            )
        }
        creating[id] = task
        defer { creating.removeValue(forKey: id) }
        let live = try await task.value
        guard !isClosed else {
            await live.shutdown()
            throw RemoteFailure.shuttingDown
        }
        sessions[id] = live
        return live
    }

    /// Called when a turn comes to rest, after the queue has ended runbloom.app's turn. The bridge
    /// tools hang their subagent reports here.
    func turnSettled(_ id: SessionID, ending: RemoteTurnEnd) async {}

    public static let installedAgents: AgentDiscovery = {
        AgentCatalog.installedKinds().filter(\.canRunWorkspaces)
    }

    public static let liveModels: ModelDiscovery = { _ in
        var records: [ModelRecord] = []
        if let codex = try? await CodexModelCatalog.live().pickerModels() {
            records += codex.filter { !$0.hidden }.map { ModelRecord(agent: AgentKind.codex.wireName, model: $0.agentModel) }
        }
        return records
    }
}

/// Lets the event hub reach the runtime that owns it without keeping it alive.
private final class WeakRuntime: @unchecked Sendable {
    // Written once in the runtime's initialiser, before the hub can call back, and only read after.
    weak var runtime: WorkspaceRuntime?
}

extension ModelRecord {
    init(agent: String, model: AgentModel) {
        self.init(agent: agent, id: model.id, label: model.displayName, efforts: model.supportedEfforts.map(\.id),
                  defaultEffort: model.defaultEffort.isEmpty ? nil : model.defaultEffort, isDefault: model.isDefault)
    }
}

extension WorkspaceOperation {
    var isArchive: Bool {
        if case .archive = self { true } else { false }
    }
}

extension String {
    /// A chat id off the wire, refused when empty rather than looked up as nothing.
    var sessionID: SessionID {
        get throws {
            guard !isEmpty, utf8.count <= 128 else { throw RemoteFailure.notFound("This conversation no longer exists.") }
            return SessionID(self)
        }
    }
}

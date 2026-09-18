import BloomProtocol
import Foundation
import Synchronization

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
    let publishing: RemotePublishing?
    public nonisolated let events: RemoteEventHub
    let admissions = RemoteAdmissions()
    let reviewCache = RemoteReviewCache()
    var terminalService: RemoteTerminals?
    /// Turns a push or pull request is running under right now, which the git credential route
    /// accepts a turn id for. See `RemotePublishing`.
    var publishingTurns: Set<String> = []

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
    var publishedWorkspace: WorkspaceRecord?
    var publishedSetupLogLength = 0
    /// What the machine can say about reaching runbloom.app, set by whoever is failing to reach it.
    /// Nil is the normal case and draws nothing. See `ReportingRecord`.
    var reporting: ReportingRecord?
    /// Which setup step is running, for the setup record. Set by the machine's setup runner.
    var setupStep: String?
    var setupStartedAt: Date?
    /// What the setup runner last found under the step's child. See `RemoteSummary.Setup.Liveness`.
    var setupLiveness: RemoteSummary.Setup.Liveness?
    /// What an agent on this machine is told about where it is running. Nil off a machine. See
    /// `BridgeBriefing`.
    let briefing: String?
    /// Whether an id somebody wants to address belongs to this team, asked of runbloom.app through
    /// the machine. **Answers `unknown` off a machine and before the list has ever arrived**, which
    /// is refused rather than guessed at. See `MemberLookup`.
    let lookUpMember: @Sendable (String) async -> MemberLookup
    /// Everybody who may be addressed, for the snapshot a client draws completion from. Empty off a
    /// machine and until the list has arrived.
    let listMembers: @Sendable () async -> [WorkspaceMember]
    /// Told when somebody has been addressed, so the machine's half can tell runbloom.app. The row
    /// is already written by then, so a machine that dies here still reports after its restart.
    let addressed: (@Sendable (AddressedReport) async -> Void)?
    /// The project's services as the machine is running them. Empty everywhere that is not a
    /// machine, which is every Mac. See `ServiceRecord`.
    var services: [ServiceRecord] = []
    var setupFinishedAt: Date?
    /// Whether the workspace's prompts must wait: setup has not finished yet.
    var holdsPromptsForSetup = false
    var archivePreviews: [String: (preview: ArchivePreviewRecord, createdAt: Date)] = [:]
    var isClosed = false
    var shutdownTask: Task<Void, Never>?
    /// Who is told what happened, for summaries, usage and the awake policy. See
    /// `WorkspaceRuntime+Reporting`.
    var activityObserver: (@Sendable (RemoteActivityEvent) async -> Void)?
    var lastSetupSucceeded: Bool?
    /// Where the agent bridge listens, or nil for no bridge tools at all, which is what tests and
    /// anything but a machine want. See `WorkspaceRuntime+Bridge`.
    let bridgeSocketPath: String?
    /// The `bloom-bridge` binary each agent's MCP configuration names. Nil also means no bridge.
    let bridgeShimPath: String?
    /// Whether this workspace runs setup scripts at all, which a client is told so it can offer to
    /// run setup rather than report that it failed to. Comes from the machine's configuration file,
    /// read once at boot, so it cannot change under a running server. See
    /// `MachineConfiguration.runSetup`; true everywhere that is not a machine.
    let runsSetup: Bool
    var bridge: BridgeServer?

    public init(
        store: Store,
        workspaceID: WorkspaceID,
        gate: any RemoteTurnGate = UngatedTurns(),
        makeRunner: @escaping RemoteRunnerFactory.Make = RemoteRunnerFactory.live,
        installedAgents: @escaping AgentDiscovery = WorkspaceRuntime.installedAgents,
        models: @escaping ModelDiscovery = WorkspaceRuntime.liveModels,
        publishing: RemotePublishing? = nil,
        runnerExitGrace: Duration = .seconds(6),
        bridgeSocketPath: String? = nil,
        bridgeShimPath: String? = BridgeRegistration.shimPath(),
        runsSetup: Bool = true,
        briefing: String? = nil,
        lookUpMember: @escaping @Sendable (String) async -> MemberLookup = { _ in .unknown },
        listMembers: @escaping @Sendable () async -> [WorkspaceMember] = { [] },
        addressed: (@Sendable (AddressedReport) async -> Void)? = nil
    ) {
        self.lookUpMember = lookUpMember
        self.listMembers = listMembers
        self.addressed = addressed
        self.briefing = briefing
        self.runsSetup = runsSetup
        self.bridgeSocketPath = bridgeSocketPath
        self.bridgeShimPath = bridgeShimPath
        self.publishing = publishing
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
        try startBridge()
        try await recoverInterruptedTurns()
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

    /// A turn that was running when this server stopped is not running now, and the transcript
    /// would otherwise stop in the middle of a sentence.
    ///
    /// **An update is a restart.** `control/update` moves the symlink and restarts the service,
    /// which kills the whole process group, agent and all, and the provider does the same when it
    /// moves a machine. Everything about that is handled: runbloom.app is told the turn ended, the
    /// queue keeps whatever had not gone yet, and the chat stops claiming to be running because
    /// `SessionLifecycle`'s `appRelaunched` row says where a mid-turn state goes. None of it is
    /// visible. What a person sees is an agent that was working a moment ago and now is not, with
    /// nothing in the transcript between the two, and the honest reading of that is "Bloom lost my
    /// turn and said nothing".
    ///
    /// So one row per chat, in the place every other failure of a turn is drawn. Written before
    /// `publishedCursor` is read, so it is part of the state a client is handed when it connects
    /// rather than an event arriving out of nowhere a moment later.
    func recoverInterruptedTurns() async throws {
        let interrupted = try await store.sessions(workspaceID: workspaceID)
            .filter { $0.state.isMidTurn && $0.archivedAt == nil }
        guard !interrupted.isEmpty else { return }
        // The same pass the Mac makes at launch, out of the same transition table, so the two
        // cannot drift: a machine has one workspace, so there is nothing else here for it to move.
        try await store.resetRunningSessions()
        let row = AgentError.serverRestarted(message: Self.restartedSentence)
        for session in interrupted {
            _ = try? await store.appendNext(sessionID: session.id, kind: .error, payload: row.raw)
        }
    }

    /// Said to somebody whose turn a restart ended. It names the machine rather than the agent,
    /// because the agent did nothing wrong, and it says what survived, because that is the first
    /// thing anybody wants to know.
    static let restartedSentence =
        "This Cloud workspace's server restarted while the agent was working, so the turn ended "
        + "here. Everything it had already written is above, and its changes are still in the "
        + "workspace."

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
        if request.operation.isHumanInput, let author = caller.author {
            presence.noteInput(author, at: Date())
            await report(.humanInput)
        }
        guard request.operation.mutates else { return await execute(request, as: caller) }
        let key = Self.journalKey(request.commandID, caller: caller)
        if let task = commands[key] {
            _ = await task.value
            return await recorded(request, key: key)
        }
        // Registered before the first suspension, so two retries arriving together share one run.
        let task = Task { await self.performOnce(request, as: caller, key: key) }
        commands[key] = task
        let reply = await task.value
        commands.removeValue(forKey: key)
        return reply
    }

    /// Scoped to the person as well as the id. A command id is chosen by the client, so one keyed
    /// by id alone let anybody who learnt another person's id read that person's recorded reply.
    private static func journalKey(_ commandID: String, caller: RemoteCaller) -> String {
        "remote.command." + (caller.author?.userID ?? "machine") + "." + commandID
    }

    private struct JournalEntry: Codable {
        var request: CommandRequest
        var reply: CommandReply?
        var recordedAt: Date

        enum CodingKeys: String, CodingKey {
            case request, reply
            case recordedAt = "recorded_at"
        }
    }

    private func performOnce(_ request: CommandRequest, as caller: RemoteCaller, key: String) async -> CommandReply {
        do {
            if try await store.setting(key) != nil { return await recorded(request, key: key) }
            try await journal(JournalEntry(request: request, reply: nil, recordedAt: Date()), key: key)
            let reply = await execute(request, as: caller)
            try await journal(JournalEntry(request: request, reply: reply, recordedAt: Date()), key: key)
            return reply
        } catch {
            return CommandReply(commandID: request.commandID, error: RemoteFailure.wire(error))
        }
    }

    private func recorded(_ request: CommandRequest, key: String) async -> CommandReply {
        do {
            guard let text = try await store.setting(key) else {
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

    private func journal(_ entry: JournalEntry, key: String) async throws {
        let data = try WireJSON.encode(entry)
        try await store.setSetting(key, String(decoding: data, as: UTF8.self))
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
        case .transcriptSearch(let query, let limit): return .search(try await searchTranscripts(query, limit: limit))
        case .newChat(let controls): return .chat(try await newChat(controls, as: caller))
        case .renameChat(let chatID, let title): try await renameChat(chatID, title: title); return .accepted
        case .closeChat(let chatID): try await closeChat(try chatID.sessionID, notifyingParent: true); return .accepted
        case .markRead(let chatID, let seq):
            _ = try await storedSession(try chatID.sessionID)
            try await store.updateLastReadSeq(sessionID: try chatID.sessionID, seq: seq)
            return .accepted
        case .setComposer(let chatID, let controls): try await setComposer(chatID, controls: controls, as: caller); return .accepted
        case .send(let chatID, let text, let audience): return try await send(chatID, text: text, audience: audience, as: caller)
        case .cancelQueued(let chatID, let promptID):
            try await queue().cancel(DeliveryID(promptID), sessionID: try chatID.sessionID)
            return .accepted
        case .stop(let chatID): try await stop(try chatID.sessionID); return .accepted
        case .answer(let chatID, let requestID, let answer): try await answerQuestion(chatID, requestID: requestID, answer: answer); return .accepted
        case .setupOutput, .files, .file, .download, .reviewSnapshot, .reviewPatch, .runScripts, .quickPrompts, .notes,
             .pullRequest, .archivePreview, .writeFile, .uploadFile, .commit, .push, .createPullRequest, .saveNotes, .renameWorkspace,
             .runSetup, .runScript, .closeTerminal, .archive, .history, .commitFiles, .commitPatch, .revertFile,
             .discardHunk:
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
        stopBridge()
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
        }, started: { [weak self] id, delivery in
            await self?.turnStarted(id, delivery: delivery)
        }, settled: { [weak self] id, ending, turnID in
            await self?.turnSettled(id, ending: ending, turnID: turnID)
        }, granted: { [weak self] grant in
            await self?.retirePersonalCredentials(where: grant.supersedes)
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
            let store = self.store, make = self.makeRunner, bridge = self.bridge, shimPath = self.bridgeShimPath
            return RemoteSession(
                runnerExitGrace: self.runnerExitGrace,
                make: { environment in
                    // Per process rather than per chat, because a relaunch on another key is a new
                    // process and registering is what revokes the token the old one held.
                    let handle = bridge.flatMap { Self.registerBridge($0, shimPath: shimPath, session: session, workspace: workspace) }
                    return make(session, workspace.path, store, environment, handle)
                },
                onStream: { [weak self] text, reset in await self?.streamed(id, text: text, reset: reset) },
                onTurnEnded: { [weak self] ending in await self?.queue().turnEnded(id, ending: ending) },
                onIdle: { [weak self] in await self?.report(.chatIdle(chat: id)) }
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

    /// Called when a turn comes to rest, after the queue has ended runbloom.app's turn.
    /// runbloom.app says the workspace became shared: everything holding one person's credentials
    /// goes. Safe to repeat, since a second call finds nothing personal left.
    public func becameShared() async {
        await retirePersonalCredentials { !$0.isEmpty }
    }

    /// Stops every agent process and ends every shell holding personal credentials `superseded`
    /// picks out. A turn running on them ends with a row saying why, and queued prompts stay
    /// queued, to start on the team key.
    public func retirePersonalCredentials(where superseded: @escaping @Sendable (Set<String>) -> Bool) async {
        guard !isClosed else { return }
        for (id, session) in sessions {
            guard await session.retirePersonal(reason: PersonalCredentials.sharedSentence, where: superseded) else { continue }
            let row = AgentError.stoppedForSharing(message: PersonalCredentials.sharedSentence)
            _ = try? await store.appendNext(sessionID: id, kind: .error, payload: row.raw)
        }
        try? await terminalService?.closeAll(where: superseded)
    }

    func turnSettled(_ id: SessionID, ending: RemoteTurnEnd, turnID: String?) async {
        await reportToParent(id, ending: ending)
        await report(.turnFinished(chat: id, turnID: turnID))
    }

    func turnStarted(_ id: SessionID, delivery: Delivery) async {
        let agent = (try? await store.session(id: id)?.agentKind) ?? .claudeCode
        await report(.turnStarted(chat: id, turnID: delivery.remoteTurnID, author: delivery.author, agent: agent))
    }

    public static let installedAgents: AgentDiscovery = {
        let found = AgentCatalog.installedKinds().filter(\.canRunWorkspaces)
        if let note = missingAgentsNote(found: found, path: Shell.environment()["PATH"] ?? ""),
           saidWhichAgentsAreMissing.withLock({ said -> Bool in
               defer { said = true }
               return !said
           }) {
            FileHandle.standardError.write(Data("bloom-runner: \(note)\n".utf8))
        }
        return found
    }

    /// Set the first time something was actually missing, so this is one line in a machine's life
    /// rather than one per `composer` call. Untouched while every agent resolves, so a machine that
    /// loses one later still says so once.
    private static let saidWhichAgentsAreMissing = Mutex(false)

    /// What to say when an agent this image is expected to carry does not resolve, or nil when they
    /// all do.
    ///
    /// **No debugger will ever attach to a machine here** (see docs/REMOTE-WORKSPACES.md), so what
    /// the machine says about itself is the only forensics there will be. One Cloud workspace was
    /// seen answering `["claude", "codex"]` while another from the same release thirty seconds later
    /// answered `["claude", "codex", "grok"]`, and nothing anywhere recorded which name was looked
    /// for or where, which is the difference between a fixable fact and a workspace that
    /// inexplicably cannot run an agent. It is not on the wire and there is no operation for it: a
    /// client has `available_agents`, and this is for whoever reads the machine afterwards.
    static func missingAgentsNote(found: [AgentKind], path: String) -> String? {
        let missing = AgentKind.allCases.filter { $0.canRunWorkspaces && !found.contains($0) }
        guard !missing.isEmpty else { return nil }
        return "no \(missing.map(\.executableName).joined(separator: ", ")) on PATH=\(path)"
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

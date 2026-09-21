import BloomProtocol
import Foundation

// The worktree itself: setup, notes, git and GitHub, run scripts, and archiving.
extension WorkspaceRuntime {
    func performOnWorktree(_ operation: WorkspaceOperation, as caller: RemoteCaller) async throws -> OperationResult {
        switch operation {
        case .setupOutput:
            let workspace = try await workspace()
            return .setupOutput(SetupOutputRecord(setup: setupRecord(workspace), log: workspace.setupLog))
        case .runScripts:
            let workspace = try await workspace()
            let settings = SettingsLoader.load(repo: workspace.path)
            return .runScripts(scripts: settings.runScripts.map { RunScriptRecord(id: $0.id, name: $0.name, command: $0.command) })
        case .quickPrompts:
            // Read on every call rather than kept, so an edit to the file is in the next menu.
            return RemoteQuickPrompts.answer(repo: try await workspace().path)
        case .notes:
            return .text(try await store.note(workspaceID: workspaceID)?.body ?? "")
        case .saveNotes(let text):
            guard text.utf8.count <= 1_048_576 else { throw RemoteFailure(.tooLarge, "The note is larger than 1 MB.") }
            _ = try await workspace()
            try await store.saveNote(workspaceID: workspaceID, body: text)
            return .accepted
        case .renameWorkspace(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else { throw RemoteFailure.invalid("Enter a shorter Bloom Cloud workspace name.") }
            _ = try await workspace()
            _ = try await store.update(workspaceID: workspaceID) { $0.name = trimmed }
            return .accepted
        case .pullRequest:
            let workspace = try await workspace()
            let pull = try await GitHub.pullRequest(forBranch: workspace.branch, worktree: workspace.path, maxAge: .seconds(30))
            return .text(pull?.url ?? "")
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteFailure.invalid("Enter a commit message.") }
            let workspace = try await workspace()
            try await Git.stageAll(in: workspace.path)
            _ = try await Git.commit(message: message, in: workspace.path, allowEmpty: false)
            return .accepted
        case .push:
            let workspace = try await workspace()
            try await asPerson(caller) { command in try await self.push(workspace, command: command) }
            return .accepted
        case .createPullRequest(let title, let body, let draft):
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteFailure.invalid("Enter a pull request title.") }
            let workspace = try await workspace()
            try await asPerson(caller) { command in
                try await self.push(workspace, command: command)
            }
            let url = try await asPerson(caller) { command in
                try await self.createPullRequest(
                    workspace, title: title, body: body, draft: draft, command: command
                )
            }
            return .text(url)
        case .runSetup:
            return try await runSetupAgain()
        case .stopSetup:
            return try await stopSetup(by: caller.author?.name ?? "")
        case .continueAfterMerge(let chatID):
            return try await continueAfterMerge(chatID: chatID, as: caller)
        case .archivePreview:
            return .archivePreview(try await prepareArchive())
        case .archive(let confirmationID):
            return try await archive(confirmationID: confirmationID)
        case .files, .searchCode, .file, .download, .reviewSnapshot, .reviewPatch, .writeFile, .uploadFile, .runScript, .closeTerminal,
             .history, .commitFiles, .commitPatch, .revertFile, .discardHunk:
            return try await performOnFiles(operation, as: caller)
        default:
            throw RemoteFailure(.internal, "This operation is not a worktree operation.")
        }
    }

    /// Runs the setup script again, by hand, with every chat quiet.
    ///
    /// **Answers once the run has started, not when it ends.** It used to hold the request open
    /// for the whole script, which is minutes for a real project, past the timeouts of the clients
    /// and proxies in between, so a slow setup that was going perfectly well read as a failed call.
    /// What is refused is still refused on the spot (setup already running, an agent working, a
    /// prompt waiting); what happens after is told the way every setup is, through the `setup`
    /// events and the log, which is where a client was already watching it.
    private func runSetupAgain() async throws -> OperationResult {
        let workspace = try await workspace()
        guard !holdsPromptsForSetup, workspace.setupState != .running, manualSetup == nil else {
            throw RemoteFailure(.busy, "Setup is already running.")
        }
        for id in try await chatIDs() {
            let busy = await sessions[id]?.isBusy == true
            let pending = try await store.pendingDeliveries(sessionID: id)
            guard !busy, pending.isEmpty else {
                throw RemoteFailure(.busy, "Stop the workspace's agents and clear queued prompts before running setup again.")
            }
        }
        // On a machine, the machine's own setup runs it, with bash: the Mac's path below launches
        // zsh, which a machine does not have. It reports its steps and its end itself.
        if let setupRerunner {
            Task { _ = await setupRerunner() }
            return .accepted
        }
        let repo = try await repo(for: workspace)
        await setupStepStarted("setup")
        let manager = WorkspaceManager(store: store)
        let port = await manager.ensurePort(for: workspace)
        // Held as a task so `stop_setup` can cancel it: cancelling is how the Mac's Stop ends a
        // setup script, and `WorkspaceManager.runSetup` files that as stopped rather than broken.
        let run = Task { await manager.runSetup(workspace: workspace, repo: repo, port: port, onOutput: { _ in }) }
        manualSetup = run
        Task { [weak self] in
            let succeeded = await run.value
            await self?.manualSetupEnded(succeeded: succeeded)
        }
        return .accepted
    }

    private func manualSetupEnded(succeeded: Bool) async {
        manualSetup = nil
        await setupFinished(succeeded: succeeded)
    }

    /// Stops whichever setup is running: one somebody ran by hand, or the machine's own.
    public func setSetupStopper(_ stopper: @escaping @Sendable (String) async -> Bool) {
        setupStopper = stopper
    }

    /// How a machine runs the setup script again by hand. See `setupRerunner`.
    public func setSetupRerunner(_ rerunner: @escaping @Sendable () async -> Bool?) {
        setupRerunner = rerunner
    }

    private func stopSetup(by name: String) async throws -> OperationResult {
        if let manualSetup {
            manualSetup.cancel()
            return .accepted
        }
        if let setupStopper, await setupStopper(name) { return .accepted }
        throw RemoteFailure(.conflict, "Setup is not running, so there is nothing to stop.")
    }

    // MARK: - Archive

    /// What archiving would lose, measured now, with an id that confirms exactly this answer.
    func prepareArchive() async throws -> ArchivePreviewRecord {
        let workspace = try await workspace()
        let report = try await WorkspaceManager(store: store).safetyReport(workspace: workspace, repo: try await repo(for: workspace))
        var agentRunning = false
        for session in sessions.values where await session.isBusy { agentRunning = true }
        let pull = try? await GitHub.pullRequest(forBranch: workspace.branch, worktree: workspace.path, maxAge: .seconds(30))
        let preview = ArchivePreviewRecord(
            confirmationID: UUID().uuidString.lowercased(), hasUncommittedChanges: report.hasUncommittedChanges,
            untrackedFiles: report.untrackedFiles, unpushedCommits: report.unpushedCommits, detachedCommits: report.detachedCommits,
            isAgentRunning: agentRunning, isPullRequestMerged: pull?.state.uppercased() == "MERGED", createdAt: Date()
        )
        archivePreviews = archivePreviews.filter { Date().timeIntervalSince($0.value.createdAt) < 600 }
        archivePreviews[preview.confirmationID] = (preview, preview.createdAt)
        return preview
    }

    /// Winds the workspace down so runbloom.app can delete the machine.
    ///
    /// **The machine does not delete itself.** runbloom.app holds the provider token and deletes the
    /// machine when the client asks it to archive; what happens here is everything that has to
    /// happen before that is safe: the confirmation is checked against a fresh measurement, every
    /// turn is stopped, and the door closes so nothing new starts on a machine about to go. A
    /// confirmation whose answer moved (a commit landed, a file appeared) comes back as a fresh
    /// preview instead, and nothing is stopped.
    func archive(confirmationID: String) async throws -> OperationResult {
        guard let accepted = archivePreviews[confirmationID], Date().timeIntervalSince(accepted.createdAt) < 600 else {
            return .archivePreview(try await prepareArchive())
        }
        try admissions.beginClosing()
        var closed = false
        defer { admissions.finishClosing(closed: closed) }
        await admissions.drain()
        let fresh = try await prepareArchive()
        guard fresh.hasUncommittedChanges == accepted.preview.hasUncommittedChanges,
              fresh.untrackedFiles == accepted.preview.untrackedFiles,
              fresh.unpushedCommits == accepted.preview.unpushedCommits,
              fresh.detachedCommits == accepted.preview.detachedCommits else {
            return .archivePreview(fresh)
        }
        for id in try await chatIDs() {
            try? await queue().pause(id)
            await sessions[id]?.stop()
        }
        await promptQueue?.shutdown()
        let live = Array(sessions.values)
        for session in live { await session.shutdown() }
        sessions.removeAll()
        archivePreviews.removeAll()
        closed = true
        return .accepted
    }

    // MARK: - Files, review and terminals

    func performOnFiles(_ operation: WorkspaceOperation, as caller: RemoteCaller) async throws -> OperationResult {
        let workspace = try await workspace()
        switch operation {
        case .files:
            return .files(paths: try await listedFiles(workspace))
        case .searchCode(let query, let limit):
            // The same list `files` answers, so a client searches exactly what it can open.
            let paths = try await listedFiles(workspace)
            return try await blocking(search: caller) {
                try RemoteCodeSearch.search(workspace: workspace, paths: paths, query: query, limit: limit)
            }
        case .history(let limit, let before):
            return .history(try await RemoteHistory.page(workspace: workspace, limit: limit, before: before))
        case .revertFile(let path, let scope):
            try await RemoteDiscard.revertFile(workspace: workspace, path: path, scope: scope)
            return .accepted
        case .discardHunk(let path, let scope, let patch):
            try await RemoteDiscard.discardHunk(workspace: workspace, path: path, scope: scope, patch: patch)
            return .accepted
        case .commitFiles(let sha):
            return .commitFiles(files: try await RemoteHistory.files(workspace: workspace, sha: sha))
        case .commitPatch(let sha, let path):
            return .reviewPatch(try await RemoteHistory.patch(workspace: workspace, sha: sha, path: path))
        case .file(let path):
            return .file(try await blocking { try RemoteReview.file(workspace: workspace, path: path) })
        case .download(let path):
            return .download(try await blocking { try RemoteFileOperations.download(workspace: workspace, path: path) })
        case .reviewSnapshot(let scope, let knownRevision, let wait):
            return .reviewSnapshot(try await reviewCache.snapshot(workspace: workspace, scope: scope, knownRevision: knownRevision, wait: wait))
        case .reviewPatch(let path, let scope, let knownRevision):
            return .reviewPatch(try await reviewCache.patch(workspace: workspace, path: path, scope: scope, knownRevision: knownRevision))
        case .writeFile(let path, let text, let revision):
            return .file(try await blocking { try RemoteFileOperations.write(workspace: workspace, path: path, text: text, revision: revision) })
        case .uploadFile(let name, let data):
            return .text(try await blocking { try RemoteFileOperations.upload(workspace: workspace, name: name, data: data) })
        case .runScript(let id):
            let settings = SettingsLoader.load(repo: workspace.path)
            guard let script = settings.runScripts.first(where: { $0.id == id }) else {
                throw RemoteFailure.notFound("This run script is no longer configured in the project.")
            }
            let name = "script-" + UUID().uuidString.lowercased().prefix(8)
            // tmux runs it as the session's command; typing it in raced the shell's own start.
            let attachment = try await terminals().attach(name: String(name), owner: caller.author?.userID, runScript: script.command)
            await attachment.close()
            return .terminal(TerminalRecord(name: String(name), title: script.name))
        case .closeTerminal(let name):
            try await terminals().close(name: name, requester: caller.author?.userID)
            return .accepted
        default:
            throw RemoteFailure(.internal, "This operation is not a file operation.")
        }
    }

    /// **Disk work off the actor, a few at a time.** A search reads every file for up to ten
    /// seconds, a download reads 8 MB and a write syncs to disk, and done inside the actor each of
    /// them held up every command, stop, event and revoke until it finished; a viewer looping a
    /// search that matches nothing kept the workspace deaf (M4 in the review of 19 September 2026).
    /// Now they run on a detached task, at most `blockingLimit` at once and one search per person,
    /// and anything over that is answered busy rather than queued behind it.
    func blocking<Value: Sendable>(search caller: RemoteCaller? = nil,
                                   _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        guard blockingInFlight < Self.blockingLimit else {
            throw RemoteFailure(.busy, "This workspace is busy reading files. Try again in a moment.")
        }
        let searcher = caller.map { $0.author?.userID ?? "" }
        if let searcher {
            guard !searchesInFlight.contains(searcher) else {
                throw RemoteFailure(.busy, "A search of yours is still running here. Wait for it before starting another.")
            }
            searchesInFlight.insert(searcher)
        }
        blockingInFlight += 1
        defer {
            blockingInFlight -= 1
            if let searcher { searchesInFlight.remove(searcher) }
        }
        return try await Task.detached(priority: .utility) { try work() }.value
    }

    static let blockingLimit = 4

    /// The workspace's terminals, started the first time anybody needs one.
    public func terminals() async throws -> RemoteTerminals {
        if let terminalService { return terminalService }
        let workspace = try await workspace()
        let service = RemoteTerminals(workspaceID: workspaceID, worktree: workspace.path, databasePath: store.path,
                                      sandbox: sandbox, sharedDirectory: sharedDirectory)
        terminalService = service
        return service
    }

    /// Each terminal's shell by name, for the git credential door. Does not start terminals.
    public func terminalPanePIDs() async -> [String: Int32] {
        await terminalService?.panePIDs() ?? [:]
    }

    /// The tmux server's process, when this runtime started one, so the git credential route can
    /// tell a shell in one of its terminals from any other process. Does not start terminals.
    public func terminalServerProcessID() async -> Int32? {
        await terminalService?.serverProcessID()
    }

    /// Every path git tracks or would track: tracked, and untracked but not ignored.
    private func listedFiles(_ workspace: Workspace) async throws -> [String] {
        let listed = try await Git.checkRaw(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: workspace.path)
        let paths = String(decoding: listed.stdout, as: UTF8.self).split(separator: "\0").map(String.init)
        return Array(Set(paths)).sorted()
    }
}

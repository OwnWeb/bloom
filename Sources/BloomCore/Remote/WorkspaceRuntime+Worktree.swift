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
            try await asPerson(caller) { environment in try await self.push(workspace, environment: environment) }
            return .accepted
        case .createPullRequest(let title, let body, let draft):
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteFailure.invalid("Enter a pull request title.") }
            let workspace = try await workspace()
            let url = try await asPerson(caller) { environment in
                try await self.createPullRequest(workspace, title: title, body: body, draft: draft, environment: environment)
            }
            return .text(url)
        case .runSetup:
            return try await runSetupAgain()
        case .stopSetup:
            return try await stopSetup(by: caller.author?.name ?? "")
        case .archivePreview:
            return .archivePreview(try await prepareArchive())
        case .archive(let confirmationID):
            return try await archive(confirmationID: confirmationID)
        case .files, .file, .download, .reviewSnapshot, .reviewPatch, .writeFile, .uploadFile, .runScript, .closeTerminal,
             .history, .commitFiles, .commitPatch, .revertFile, .discardHunk:
            return try await performOnFiles(operation, as: caller)
        default:
            throw RemoteFailure(.internal, "This operation is not a worktree operation.")
        }
    }

    /// Runs the setup script again, by hand, with every chat quiet.
    private func runSetupAgain() async throws -> OperationResult {
        let workspace = try await workspace()
        guard !holdsPromptsForSetup, workspace.setupState != .running else {
            throw RemoteFailure(.busy, "Setup is already running.")
        }
        for id in try await chatIDs() {
            let busy = await sessions[id]?.isBusy == true
            let pending = try await store.pendingDeliveries(sessionID: id)
            guard !busy, pending.isEmpty else {
                throw RemoteFailure(.busy, "Stop the workspace's agents and clear queued prompts before running setup again.")
            }
        }
        let repo = try await repo(for: workspace)
        await setupStepStarted("setup")
        let manager = WorkspaceManager(store: store)
        let port = await manager.ensurePort(for: workspace)
        // Held as a task so `stop_setup` can cancel it: cancelling is how the Mac's Stop ends a
        // setup script, and `WorkspaceManager.runSetup` files that as stopped rather than broken.
        let run = Task { await manager.runSetup(workspace: workspace, repo: repo, port: port, onOutput: { _ in }) }
        manualSetup = run
        let succeeded = await run.value
        manualSetup = nil
        await setupFinished(succeeded: succeeded)
        if run.isCancelled { throw RemoteFailure(.conflict, "Setup was stopped before it finished.") }
        guard succeeded else { throw RemoteFailure(.internal, "Setup failed. Check the setup output before trying again.") }
        return .accepted
    }

    /// Stops whichever setup is running: one somebody ran by hand, or the machine's own.
    public func setSetupStopper(_ stopper: @escaping @Sendable (String) async -> Bool) {
        setupStopper = stopper
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
            let listed = try await Git.checkRaw(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: workspace.path)
            let paths = String(decoding: listed.stdout, as: UTF8.self).split(separator: "\0").map(String.init)
            return .files(paths: Array(Set(paths)).sorted())
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
            return .file(try RemoteReview.file(workspace: workspace, path: path))
        case .download(let path):
            return .download(try RemoteFileOperations.download(workspace: workspace, path: path))
        case .reviewSnapshot(let scope, let knownRevision, let wait):
            return .reviewSnapshot(try await reviewCache.snapshot(workspace: workspace, scope: scope, knownRevision: knownRevision, wait: wait))
        case .reviewPatch(let path, let scope, let knownRevision):
            return .reviewPatch(try await reviewCache.patch(workspace: workspace, path: path, scope: scope, knownRevision: knownRevision))
        case .writeFile(let path, let text, let revision):
            return .file(try RemoteFileOperations.write(workspace: workspace, path: path, text: text, revision: revision))
        case .uploadFile(let name, let data):
            return .text(try RemoteFileOperations.upload(workspace: workspace, name: name, data: data))
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

    /// The workspace's terminals, started the first time anybody needs one.
    public func terminals() async throws -> RemoteTerminals {
        if let terminalService { return terminalService }
        let workspace = try await workspace()
        let service = RemoteTerminals(workspaceID: workspaceID, worktree: workspace.path, databasePath: store.path)
        terminalService = service
        return service
    }
}

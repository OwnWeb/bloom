import BloomCore
import Foundation

/// Brings the machine's one workspace up: the checkout, the repository's scripts, then its
/// services.
///
/// **Every create is cold.** A Sprite cannot start from another's checkpoint, so the first start of
/// Bloom Runner runs the whole of it: clone, create the branch, `prepare`, `setup`, `resume`, then
/// the services. Every later start, after an update or a cold wake that dropped memory, runs only
/// `resume` and the services, because `resume` is the script that exists to pick fresh environment
/// up and the rest has already happened on this disk. See docs/REMOTE-WORKSPACES.md, "Setup".
///
/// **A failed step ends the sequence, and the next start tries the whole of it again.** Only a
/// sequence that succeeded is recorded as done. A `setup` that failed because a team variable was
/// missing is the ordinary case, and the fix for it (setting the variable on runbloom.app, which
/// restarts nothing) should not need a person to find a "run setup again" button. Prompts are let go
/// after a failure all the same, as on the Mac, because an agent can read the log and fix the
/// script; the services wait for a setup that succeeded, because a dev server started against a
/// half-migrated database only adds a second error to read.
///
/// **The environment lives only in processes.** Team and project values from runbloom.app, and the
/// `BLOOM_*` variables, are handed to each script and service as it starts and never written to
/// disk. A script that writes them into `.env` has made that choice itself.
public actor MachineSetup {
    public static let completedSetting = "remote.setup.completed"

    public struct Timeouts: Sendable, Hashable {
        public var clone: Duration
        public var prepare: Duration
        public var setup: Duration
        public var resume: Duration

        public init(clone: Duration, prepare: Duration, setup: Duration, resume: Duration) {
            self.clone = clone
            self.prepare = prepare
            self.setup = setup
            self.resume = resume
        }

        /// An hour for `prepare` and `setup`, because apt, a database server and a cold
        /// `composer install` together measured two and a half minutes for one project and nobody
        /// has measured the slowest. Ten minutes for `resume`, which runs on every wake and should
        /// never be doing that kind of work.
        public static let standard = Timeouts(clone: .seconds(30 * 60), prepare: .seconds(60 * 60), setup: .seconds(60 * 60), resume: .seconds(10 * 60))
    }

    /// How long a timed-out step has between SIGTERM and SIGKILL.
    static let stopGrace = Duration.seconds(10)

    private let runtime: WorkspaceRuntime
    private let store: Store
    private let configuration: MachineConfiguration
    private let layout: MachineLayout
    private let machineEnvironment: MachineEnvironment
    private let services: ServiceSupervisor
    private let gitTools: MachineGitTools
    private let cloneURL: @Sendable (_ repository: String) -> String
    private let gitGlobalConfig: String?
    private let timeouts: Timeouts
    private var isRunning = false

    /// The `gh` wrapper's directory. Put it first on an agent's PATH, so the agent's `gh` asks
    /// Bloom Runner for a token too.
    public nonisolated let binDirectory: String

    /// - Parameters:
    ///   - serverExecutable: the Bloom Runner that git and the `gh` wrapper call back into.
    ///   - cloneURL: where `owner/name` is cloned from. GitHub, except in tests.
    ///   - gitGlobalConfig: a file to use as git's global configuration instead of the machine
    ///     user's `~/.gitconfig`, for tests. Handed to every script and service as
    ///     `GIT_CONFIG_GLOBAL`.
    public init(
        runtime: WorkspaceRuntime,
        store: Store,
        configuration: MachineConfiguration,
        layout: MachineLayout,
        environment: MachineEnvironment,
        services: ServiceSupervisor,
        serverExecutable: String = MachineSetup.currentExecutable,
        cloneURL: @escaping @Sendable (_ repository: String) -> String = MachineSetup.gitHubCloneURL,
        gitGlobalConfig: String? = nil,
        timeouts: Timeouts = .standard
    ) {
        self.runtime = runtime
        self.store = store
        self.configuration = configuration
        self.layout = layout
        machineEnvironment = environment
        self.services = services
        gitTools = MachineGitTools(
            serverExecutable: serverExecutable, dataDirectory: layout.dataDirectory,
            serverPort: layout.serverPort, repository: configuration.repository
        )
        self.cloneURL = cloneURL
        self.gitGlobalConfig = gitGlobalConfig
        self.timeouts = timeouts
        binDirectory = gitTools.binDirectory
    }

    /// Never a token in the URL: the credential helper supplies one when git asks.
    public static let gitHubCloneURL: @Sendable (String) -> String = { "https://github.com/\($0).git" }

    /// This process's path as it was started, made absolute but with symlinks left alone:
    /// `/opt/bloom/current/bin/Bloom Runner` has to stay `current`, because the versioned directory
    /// it points at today is deleted by a later update.
    public static var currentExecutable: String {
        let argument = CommandLine.arguments.first ?? "bloom-runner"
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument).standardized.path }
        if argument.contains("/") {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argument).standardized.path
        }
        return Shell.which(argument) ?? argument
    }

    private var setupDirectory: String { layout.dataDirectory + "/setup" }

    /// What Bloom Runner calls at every start.
    public func run() async {
        let completed = (try? await store.setting(Self.completedSetting)) == "1"
        if completed {
            await resumeAfterRestart()
        } else {
            await runWholeSequence()
        }
    }

    /// Clone, `prepare`, `setup`, `resume`, then the services. Returns whether setup succeeded.
    @discardableResult
    public func runWholeSequence() async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }

        await machineEnvironment.refresh()
        let environment = await scriptEnvironment()
        let log = SetupLog(store: store, workspaceID: runtime.workspaceID, directory: setupDirectory)
        await configureGit(environment: environment, log: log)

        // A run the machine was stopped in the middle of left its output in the row; a person
        // watching setup should see this run added to it rather than the first attempt vanishing.
        let interrupted = (try? await store.workspace(id: runtime.workspaceID))?.setupState == .running
        var succeeded = await cloneIfNeeded(environment: environment, log: log, continuing: interrupted)
        let scripts = MachineScripts.load(repo: layout.worktree)
        if succeeded {
            for problem in scripts.problems { await log.note(problem) }
            if !scripts.hasCloudSetup { await log.note(Self.noCloudSetupNote(hasSetupScript: scripts.setup != nil)) }
            let steps: [(String, ScriptLaunch?, Duration)] = [
                ("prepare", scripts.prepare, timeouts.prepare),
                ("setup", scripts.setup, timeouts.setup),
                ("resume", scripts.resume, timeouts.resume),
            ]
            for (name, launch, timeout) in steps where succeeded {
                succeeded = await runScript(name, launch, timeout: timeout, environment: environment, log: log, continuing: interrupted)
            }
        }
        if await interruptedByShutdown(log: log) { return false }
        await settle(log: log, succeeded: succeeded)
        guard succeeded else { return false }
        try? await store.setSetting(Self.completedSetting, "1")
        await services.start(scripts.services, environment: environment)
        return true
    }

    /// `resume` with fresh environment, then the services.
    @discardableResult
    public func resumeAfterRestart() async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }

        await machineEnvironment.refresh()
        let environment = await scriptEnvironment()
        let log = SetupLog(store: store, workspaceID: runtime.workspaceID, directory: setupDirectory)
        await configureGit(environment: environment, log: log)
        let scripts = MachineScripts.load(repo: layout.worktree)
        let succeeded = await runScript("resume", scripts.resume, timeout: timeouts.resume, environment: environment, log: log, continuing: true)
        if await interruptedByShutdown(log: log) { return false }
        if await log.hasBegun { await settle(log: log, succeeded: succeeded) }
        guard succeeded else { return false }
        await services.start(scripts.services, environment: environment)
        return true
    }

    /// Stops the services and starts them again with the environment as it is now, for when
    /// runbloom.app says the team or project environment changed.
    public func restartServices() async {
        await services.restartAll(environment: await scriptEnvironment())
    }

    /// The machine's own environment with Bloom's on top, for every script and service.
    public func scriptEnvironment() async -> [String: String] {
        var environment = Shell.environment()
        for (key, value) in await machineEnvironment.values { environment[key] = value }
        // The same names the Mac hands a setup script, because repositories in the wild already
        // read them: a script that starts with `set -u` and `cd "$BLOOM_ROOT_PATH"` fails on an
        // unbound variable before it reaches anything a machine could not do. On a machine the
        // clone is both the worktree and the repository root, and there is one workspace, so the
        // pair carry the same path.
        let variables = WorkspaceScriptVariables(
            isLocal: false, workspaceName: WorkspaceScriptVariables.workspaceName(branch: configuration.branch),
            workspaceID: configuration.workspaceID, workspacePath: layout.worktree,
            projectName: Self.projectName(repository: configuration.repository), rootPath: layout.worktree,
            defaultBranch: configuration.baseBranch, port: layout.appPort
        )
        environment.merge(variables.environment) { _, script in script }
        environment["BLOOM_PUBLIC_URL"] = configuration.publicURL
        environment["BLOOM_PUBLIC_HOST"] = configuration.publicHost
        environment["BLOOM_APP_PORT"] = String(layout.appPort)
        environment["BLOOM_WORKSPACE_ID"] = configuration.workspaceID
        environment["BLOOM_BRANCH"] = configuration.branch
        environment["BLOOM_REPOSITORY"] = configuration.repository
        environment["BLOOM_DATA_DIR"] = layout.dataDirectory
        environment["BLOOM_RUNNER_PORT"] = String(layout.serverPort)
        environment["PATH"] = binDirectory + ":" + (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        // A missing credential must fail the command, not leave it waiting for a password on a
        // terminal nobody is at.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if let gitGlobalConfig { environment["GIT_CONFIG_GLOBAL"] = gitGlobalConfig }
        return environment
    }

    /// The repository's own name rather than the clone's folder, which on a machine is always
    /// `workspace` and would give every project the same database name.
    static func projectName(repository: String) -> String {
        WorkspaceScriptVariables.identifier(repository.split(separator: "/").last.map(String.init) ?? repository)
    }

    /// What somebody is told before a repository with no Cloud workspace setup is set up anyway.
    static func noCloudSetupNote(hasSetupScript: Bool) -> String {
        let start = "This project has no Cloud workspace setup yet. Add .bloom/settings.toml with a "
            + "[scripts] prepare (what the machine needs installed), setup (this workspace's own "
            + "setup) and [[services]] (what to run and how to know it is up)."
        return hasSetupScript
            ? start + " Until then the project's existing setup script runs as it is, and a script "
                + "written for a Mac may not work on a machine."
            : start + " Nothing is set up for now, so the worktree is the repository as it was cloned."
    }

    // MARK: - Steps

    /// A shutdown cancels setup, and the step it stopped exits non-zero. Filing that as a failure
    /// would tell runbloom.app setup failed and let the queue start turns while the machine goes
    /// down, so it is filed as interrupted and nothing else happens.
    private func interruptedByShutdown(log: SetupLog) async -> Bool {
        guard Task.isCancelled else { return false }
        if await log.hasBegun { await log.interrupt() }
        return true
    }

    /// The row's state and the runtime's record both say how it ended. A sequence where nothing
    /// ran is filed as skipped, as the Mac files a workspace with no setup script.
    private func settle(log: SetupLog, succeeded: Bool) async {
        if await log.hasBegun {
            await log.finish(succeeded: succeeded)
        } else {
            let notes = await log.text.trimmingCharacters(in: .newlines)
            _ = try? await store.update(workspaceID: runtime.workspaceID) { $0.apply(.runSkipped(note: notes.isEmpty ? nil : notes)) }
        }
        await runtime.setupFinished(succeeded: succeeded)
    }

    private func begin(_ step: String, log: SetupLog, continuing: Bool) async {
        await log.begin(continuing: continuing)
        await log.startStep(step)
        await runtime.setupStepStarted(step)
    }

    /// Written at every start, quietly: a failure here is noted in the log but does not stop
    /// setup, since a public repository clones without a credential and the scripts may not push.
    private func configureGit(environment: [String: String], log: SetupLog) async {
        for arguments in gitTools.configCommands {
            let result = try? await Shell.run("git", arguments, env: environment, timeout: .seconds(30))
            // `--unset-all` answers 5 when there was nothing to unset, which is the usual case.
            if let result, !result.ok, !(arguments.contains("--unset-all") && result.status == 5) {
                await log.note("git \(arguments.joined(separator: " ")) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        do {
            try gitTools.writeGhWrapper()
        } catch {
            await log.note("The gh wrapper could not be written to \(gitTools.ghWrapperPath): \(error.localizedDescription)")
        }
    }

    /// Whether the clone and its checkout both finished, recorded apart from `.git` existing:
    /// a clone killed by the watchdog or a checkout that failed leaves `.git` behind, and the next
    /// start would otherwise run the scripts on the default branch of a half-made repository.
    static let clonedSetting = "remote.setup.cloned"

    private func cloneIfNeeded(environment: [String: String], log: SetupLog, continuing: Bool = false) async -> Bool {
        let worktree = layout.worktree
        let cloned = (try? await store.setting(Self.clonedSetting)) == "1"
        // A setup that once completed had a whole clone, whatever the marker says.
        let completed = (try? await store.setting(Self.completedSetting)) == "1"
        if FileManager.default.fileExists(atPath: worktree + "/.git") && (cloned || completed) { return true }
        await begin("clone", log: log, continuing: continuing)
        // Only an earlier attempt of this step has written here. Prompts wait for setup, so before
        // the clone is marked finished there is no work of anybody's in it to lose.
        try? FileManager.default.removeItem(atPath: worktree)
        try? FileManager.default.createDirectory(atPath: (worktree as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var succeeded = await runProcess(
            "git", ["clone", cloneURL(configuration.repository), worktree],
            directory: nil, timeout: timeouts.clone, environment: environment, log: log
        )
        if succeeded {
            // The branch exists on GitHub when the workspace was made from one; otherwise it starts
            // from the base branch, untracked, so a first `git push -u` names its own upstream
            // rather than pushing into the base.
            let branch = configuration.branch
            let remote = try? await Shell.run(
                "git", ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], cwd: worktree, env: environment, timeout: .seconds(30)
            )
            let arguments = remote?.ok == true
                ? ["checkout", "-B", branch, "origin/\(branch)"]
                : ["checkout", "--no-track", "-B", branch, "origin/\(configuration.baseBranch)"]
            succeeded = await runProcess("git", arguments, directory: worktree, timeout: .seconds(5 * 60), environment: environment, log: log)
        }
        if succeeded, !Task.isCancelled {
            try? await store.setSetting(Self.clonedSetting, "1")
        } else if !Task.isCancelled {
            // git's own message says what went wrong to somebody who knows git; this says what to
            // do about the two that a person can act on.
            await log.note("\(configuration.repository) could not be cloned. Check that the repository still exists and that "
                + "Bloom's GitHub App is installed for it, then run setup again.")
        }
        await log.endStep()
        return succeeded
    }

    private func runScript(
        _ step: String, _ launch: ScriptLaunch?, timeout: Duration, environment: [String: String], log: SetupLog, continuing: Bool
    ) async -> Bool {
        guard let launch else { return true }
        guard let command = MachineScripts.command(for: launch) else {
            // Skipped rather than failed, as on the Mac: a settings file pointing at a script that
            // is not committed yet should not cost anybody their workspace.
            if case .missing(let path) = launch {
                await log.begin(continuing: continuing)
                await log.note("The settings file names \(path) as the \(step) script and there is nothing there, so nothing ran.")
            }
            return true
        }
        await begin(step, log: log, continuing: continuing)
        let succeeded = await runProcess(command.executable, command.arguments, directory: layout.worktree, timeout: timeout,
                                         environment: environment, log: log, step: step)
        await log.endStep()
        return succeeded
    }

    private func runProcess(
        _ executable: String, _ arguments: [String], directory: String?, timeout: Duration, environment: [String: String],
        log: SetupLog, step: String? = nil
    ) async -> Bool {
        let process = StreamingProcess(executable: executable, arguments: arguments, cwd: directory, environment: environment)
        let lines = process.lines
        let watchdog = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            process.terminate()
            // Cancelled once the process has exited, and `kill` does nothing to a process that
            // has, so the second sleep ending early is harmless.
            try? await Task.sleep(for: Self.stopGrace)
            process.kill()
            return true
        }
        // A shutdown cancels this task, which ends `lines` and with it sends SIGTERM. A script that
        // ignores it would hold shutdown until its step timeout, up to an hour, so it gets the
        // same grace as the watchdog gives and is then killed.
        let status = await withTaskCancellationHandler {
            do {
                for try await line in lines { await log.append(line) }
            } catch {
                await log.append("[bloom] \(error)")
            }
            return await process.exitStatus
        } onCancel: {
            process.terminate()
            Task {
                try? await Task.sleep(for: Self.stopGrace)
                process.kill()
            }
        }
        watchdog.cancel()
        if await watchdog.value {
            await log.note("This step took longer than \(Self.minutes(timeout)) and was stopped.")
            return false
        }
        if status != 0 {
            // Named, because a workspace's own summary shows the last lines of this and "exited
            // with status 1" alone does not say which of three scripts it was.
            await log.note(step.map { "The \($0) script exited with status \(status)." } ?? "Exited with status \(status).")
        }
        return status == 0
    }

    static func minutes(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        let (count, unit) = seconds >= 60 ? (seconds / 60, "minute") : (seconds, "second")
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}

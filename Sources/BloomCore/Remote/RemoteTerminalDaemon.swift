import Foundation

/// The tmux server behind the workspace's terminals, owned by this process.
///
/// On Linux, Foundation tracks a child's exit through a descriptor that tmux's daemon inherits
/// when it forks away, so a tmux started the ordinary way leaves that tracking waiting forever.
/// Running it in the foreground with `-D` avoids the daemonising fork, and makes the server a
/// child this runtime starts, waits on and stops, independently of any attached client. On a Mac
/// tmux daemonises as it always has and nothing here starts it.
actor RemoteTerminalDaemon {
    private var process: StreamingProcess?
    private var pump: Task<Void, Never>?
    private var starting: Task<Void, Error>?
    private var command: TmuxCommand?
    private var isClosed = false
    private var shutdownTask: Task<Void, Never>?
    private let ownsDaemon: Bool
    private let makeProcess: @Sendable (TmuxCommand, String) -> StreamingProcess
    private let run: @Sendable (TmuxCommand, [String], String) async throws -> ShellResult

    init(ownsDaemon: Bool? = nil,
         makeProcess: (@Sendable (TmuxCommand, String) -> StreamingProcess)? = nil,
         run: (@Sendable (TmuxCommand, [String], String) async throws -> ShellResult)? = nil) {
        #if os(Linux)
        self.ownsDaemon = ownsDaemon ?? true
        #else
        self.ownsDaemon = ownsDaemon ?? false
        #endif
        self.makeProcess = makeProcess ?? { command, cwd in
            StreamingProcess(
                executable: command.executable, arguments: command.arguments(["-D"]), cwd: cwd,
                environment: Shell.terminalEnvironment(inheriting: Shell.environment())
            )
        }
        self.run = run ?? { command, arguments, cwd in
            try await Shell.run(
                command.executable, command.arguments(arguments), cwd: cwd,
                environment: Shell.terminalEnvironment(inheriting: Shell.environment()), timeout: .seconds(5)
            )
        }
    }

    func start(command: TmuxCommand, cwd: String) async throws {
        guard !isClosed else { throw RemoteFailure.shuttingDown }
        self.command = command
        guard ownsDaemon else { return }
        if let starting { return try await starting.value }
        if process?.isRunning == true { return }
        let task = Task { try await self.launch(command: command, cwd: cwd) }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch(command: TmuxCommand, cwd: String) async throws {
        try Task.checkCancellation()
        guard !isClosed else { throw RemoteFailure.shuttingDown }
        let process = makeProcess(command, cwd)
        self.process = process
        let lines = process.lines
        let pump = Task {
            do { for try await _ in lines {} } catch {
                // The readiness probe below is what reports a terminal server that failed to start.
            }
        }
        self.pump = pump
        do {
            for _ in 0..<30 {
                let probe = try await run(command, ["show-options", "-g", "exit-empty"], cwd)
                try Task.checkCancellation()
                guard !isClosed else { throw RemoteFailure.shuttingDown }
                if probe.ok { return }
                guard process.isRunning else { throw RemoteFailure(.unavailable, "The server terminal could not start.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RemoteFailure(.unavailable, "The server terminal did not become ready.")
        } catch {
            await RemoteTerminalProcessLifetime.stop(process).value
            pump.cancel()
            await pump.value
            self.process = nil
            self.pump = nil
            throw error
        }
    }

    /// The foreground tmux server's process, while this owns one and it runs.
    var serverProcessID: Int32? {
        guard ownsDaemon, let process, process.processIdentifier > 0 else { return nil }
        return process.processIdentifier
    }

    /// Whether replacing this runtime now would cut somebody off: a client attached to tmux (SSH
    /// attaches directly and never passes through an attachment here), or a pane running
    /// something other than an idle shell.
    func hasActiveWork() async -> Bool {
        guard starting == nil else { return true }
        guard let command else { return false }
        let directory = URL(fileURLWithPath: command.configPath).deletingLastPathComponent().path
        do {
            let clients = try await run(command, ["list-clients", "-F", "#{client_session}"], directory)
            if clients.ok, !clients.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            let panes = try await run(command, ["list-panes", "-a", "-F", "#{pane_dead}\t#{pane_current_command}\t#{pane_pid}"], directory)
            // A reaped foreground daemon has no terminal work. A live one that cannot be
            // inspected must not be treated as idle.
            guard panes.ok else { return process?.isRunning == true }
            return Self.panesBlockMaintenance(panes.stdout)
        } catch { return true }
    }

    static func panesBlockMaintenance(_ output: String, children: (Int32) -> String? = processChildren) -> Bool {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "0" || fields[0] == "1" else { return true }
            if fields[0] == "1" { continue }
            guard ["bash", "zsh", "sh", "dash", "fish"].contains(String(fields[1])),
                  let pid = Int32(fields[2]), pid > 1, let running = children(pid),
                  running.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        }
        return false
    }

    private static func processChildren(_ pid: Int32) -> String? {
        #if os(Linux)
        return try? String(contentsOfFile: "/proc/\(pid)/task/\(pid)/children", encoding: .utf8)
        #else
        // Replacing a running server is a Linux concern. Unknown process state fails closed.
        return nil
        #endif
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isClosed = true
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        await task.value
    }

    private func finishShutdown() async {
        if let starting {
            starting.cancel()
            _ = try? await starting.value
        }
        // Control commands run in the state directory rather than a worktree that may already
        // have been archived. The start has settled before this last cleanup.
        if let command {
            let directory = URL(fileURLWithPath: command.configPath).deletingLastPathComponent().path
            _ = try? await run(command, ["kill-server"], directory)
        }
        if let process { await RemoteTerminalProcessLifetime.stop(process).value }
        pump?.cancel()
        await pump?.value
        process = nil
        pump = nil
        command = nil
    }

    deinit {
        process?.terminate()
        pump?.cancel()
    }
}

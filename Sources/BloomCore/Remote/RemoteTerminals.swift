import Foundation

/// The workspace's terminals: tmux sessions on a private socket, and the attachments a WebSocket
/// handler reads and writes.
///
/// The socket and its configuration sit beside the database, as on the Mac, so a server pointed
/// at another database cannot adopt or kill these sessions. A session outlives every attachment
/// to it; only `close(name:)` or `shutdown()` ends a shell.
public actor RemoteTerminals {
    public nonisolated let workspaceID: WorkspaceID
    private let worktree: String
    private let databasePath: String
    private let daemon: RemoteTerminalDaemon
    private let makeAttachProcess: @Sendable (TmuxCommand, String, String) -> StreamingProcess
    private var attachments: [UUID: RemoteTerminalAttachment] = [:]
    private var closed = false

    public static let attachmentLimit = 32

    public init(workspaceID: WorkspaceID, worktree: String, databasePath: String) {
        self.init(workspaceID: workspaceID, worktree: worktree, databasePath: databasePath, daemon: RemoteTerminalDaemon())
    }

    init(workspaceID: WorkspaceID, worktree: String, databasePath: String, daemon: RemoteTerminalDaemon,
         makeAttachProcess: (@Sendable (TmuxCommand, String, String) -> StreamingProcess)? = nil) {
        self.workspaceID = workspaceID
        self.worktree = worktree
        self.databasePath = databasePath
        self.daemon = daemon
        self.makeAttachProcess = makeAttachProcess ?? { command, session, cwd in
            StreamingProcess(executable: command.executable,
                             arguments: command.arguments(["-C", "attach-session", "-t", "=" + session]),
                             cwd: cwd, environment: Shell.environment(extra: ["TERM": "xterm-256color"]))
        }
    }

    /// The tmux session behind a terminal name, created when it does not exist yet.
    ///
    /// `environment` reaches the shell only when the session is created: tmux reads `-e` at
    /// `new-session` and never again, so a session that already exists keeps the environment it
    /// started with. That is the right answer for a person's own keys, which belong to the shell
    /// they opened rather than to whoever attaches later.
    @discardableResult
    public func ensureSession(name: String, environment: [String: String] = [:]) async throws -> String {
        guard !closed else { throw RemoteFailure.shuttingDown }
        try Self.validate(name: name)
        for key in environment.keys where key.isEmpty || key.contains("=") || key.contains("\0") {
            throw RemoteFailure.invalid("Environment variable names cannot be empty or contain \"=\".")
        }
        let command = try tmuxCommand()
        try await daemon.start(command: command, cwd: worktree)
        let session = TmuxSessions.sessionName(workspaceID: workspaceID, paneID: name)
        let exists = try await Shell.run(command.executable, command.arguments(["has-session", "-t", "=" + session]), cwd: worktree)
        guard !exists.ok else { return session }
        var arguments = ["new-session", "-d", "-s", session, "-c", worktree]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            arguments += ["-e", "\(key)=\(value)"]
        }
        let created = try await Shell.run(command.executable, command.arguments(arguments), cwd: worktree)
        if !created.ok {
            // Two clients opening the same new terminal at once: one of them creates it.
            let raced = try await Shell.run(command.executable, command.arguments(["has-session", "-t", "=" + session]), cwd: worktree)
            guard raced.ok else { throw RemoteFailure(.unavailable, created.stderr) }
        }
        return session
    }

    /// Attaches to a terminal, creating its session first when there is none.
    public func attach(
        name: String, environment: [String: String] = [:], columns: Int = 80, rows: Int = 24
    ) async throws -> RemoteTerminalAttachment {
        let session = try await ensureSession(name: name, environment: environment)
        guard !closed else { throw RemoteFailure.shuttingDown }
        guard attachments.count < Self.attachmentLimit else {
            throw RemoteFailure(.unavailable, "Too many terminal connections are open.")
        }
        let command = try tmuxCommand()
        let id = UUID()
        let attachment = RemoteTerminalAttachment(
            name: name, session: session, process: makeAttachProcess(command, session, worktree),
            onClose: { [weak self] in await self?.forget(id) }
        )
        attachments[id] = attachment
        await attachment.start(columns: columns, rows: rows)
        return attachment
    }

    private func forget(_ id: UUID) {
        attachments[id] = nil
    }

    /// Ends a terminal's shell. Its attachments see their output finish.
    public func close(name: String) async throws {
        try Self.validate(name: name)
        guard let executable = Shell.which("tmux") else { return }
        let command = TmuxCommand(executable: executable, socketName: socketName, configPath: configurationPath)
        let session = TmuxSessions.sessionName(workspaceID: workspaceID, paneID: name)
        _ = try await Shell.run(executable, command.arguments(["kill-session", "-t", "=" + session]), cwd: stateDirectory)
    }

    /// Ends every shell this workspace has, which is what archiving it means for its terminals.
    public func closeAll() async throws {
        guard let executable = Shell.which("tmux") else { return }
        let command = TmuxCommand(executable: executable, socketName: socketName, configPath: configurationPath)
        let listed = try await Shell.run(executable, command.arguments(["list-sessions", "-F", "#{session_name}"]), cwd: stateDirectory)
        guard listed.ok else { return }
        let names = TmuxSessions.sessions(ofWorkspace: workspaceID, in: TmuxSessions.parseSessionList(listed.stdout))
        for name in names {
            _ = try await Shell.run(executable, command.arguments(["kill-session", "-t", "=" + name]), cwd: stateDirectory)
        }
    }

    /// Whether replacing the server now would cut somebody off.
    public func hasActiveWork() async -> Bool {
        if !attachments.isEmpty { return true }
        return await daemon.hasActiveWork()
    }

    public func shutdown() async {
        closed = true
        let open = Array(attachments.values)
        for attachment in open { await attachment.close() }
        await daemon.shutdown()
    }

    /// Whether a terminal name would be accepted, for a caller deciding before it has anything to
    /// throw into, such as a WebSocket upgrade.
    public static func isValid(name: String) -> Bool { (try? validate(name: name)) != nil }

    static func validate(name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 64,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw RemoteFailure.invalid("Use letters, numbers, hyphens or underscores for the terminal name.")
        }
    }

    private var stateDirectory: String { URL(fileURLWithPath: databasePath).deletingLastPathComponent().path }
    private var configurationPath: String { URL(fileURLWithPath: stateDirectory).appendingPathComponent("tmux.conf").path }
    private var socketName: String { TmuxSessions.socketName(databasePath: databasePath) }

    private func tmuxCommand() throws -> TmuxCommand {
        guard let executable = Shell.which("tmux") else {
            throw RemoteFailure(.unavailable, "Install tmux on the server to use terminals.")
        }
        if !FileManager.default.fileExists(atPath: configurationPath) {
            try TmuxSessions.configuration(defaultShell: LoginShell.path()).write(toFile: configurationPath, atomically: true, encoding: .utf8)
        }
        return TmuxCommand(executable: executable, socketName: socketName, configPath: configurationPath)
    }
}

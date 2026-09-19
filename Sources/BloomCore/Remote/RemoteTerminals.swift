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
    /// The session being created now, which the next creation waits behind. Creation sets tmux's
    /// global `update-environment` for the moment it runs, and two at once would each pick up the
    /// other's list.
    private var creating: Task<Void, Error>?

    /// The tmux user option holding who opened a session.
    static let ownerOption = "@bloom_owner"
    /// The tmux user option holding the session's `RemoteTurnGrant.personalMarks`, space separated.
    static let personalOption = "@bloom_personal"

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
    /// `environment` reaches the shell only when the session is created, and never through tmux's
    /// arguments: a command line is readable by every process on the machine, and these are
    /// people's keys. tmux copies the variables `update-environment` names from the creating
    /// client's own environment, so they are handed to that one short-lived process instead. A
    /// session that already exists keeps the environment it started with, which is the right
    /// answer for a person's own keys: they belong to the shell they opened.
    ///
    /// **A terminal belongs to whoever opened it.** Its shell carries that person's key, their
    /// personal environment and the turn their git credentials are asked for under, so somebody
    /// else attaching by name would act as them. `owner` nil is the server's own, such as the
    /// shell a run script is typed into, which anybody may open.
    @discardableResult
    /// `runScript` is run by tmux as the session's own command when the session is created, with a
    /// login shell left behind it.
    ///
    /// **Not typed into the shell.** A run script used to be sent as keystrokes the moment the
    /// session existed, and on a machine whose shell takes a moment to start (a profile that
    /// sources anything, a cold page cache) those keystrokes went into a shell that was not reading
    /// yet: the terminal opened, the pane stayed empty, and nothing anywhere said the script had
    /// not run. Measured on a Sprite with a three second `.bashrc`. Handing the command to tmux
    /// removes the race rather than waiting longer for it.
    public func ensureSession(name: String, environment: [String: String] = [:], owner: String? = nil,
                              personal: Set<String> = [], runScript: String? = nil) async throws -> String {
        guard !closed else { throw RemoteFailure.shuttingDown }
        try Self.validate(name: name)
        for key in environment.keys where !Self.isValidVariableName(key) {
            throw RemoteFailure.invalid("Environment variable names can only hold letters, digits and underscores.")
        }
        let command = try tmuxCommand()
        try await daemon.start(command: command, cwd: worktree)
        let session = TmuxSessions.sessionName(workspaceID: workspaceID, paneID: name)
        if try await exists(session, command: command) {
            try await requireOwner(owner, of: session, command: command)
            return session
        }
        let previous = creating
        let creation = Task { [worktree] in
            _ = try? await previous?.value
            try await Self.create(session: session, environment: environment, owner: owner, personal: personal,
                                  command: command, worktree: worktree, runScript: runScript)
        }
        creating = creation
        do {
            try await creation.value
        } catch {
            // Two clients opening the same new terminal at once: one of them creates it.
            guard try await exists(session, command: command) else { throw error }
            try await requireOwner(owner, of: session, command: command)
        }
        return session
    }

    private static func create(
        session: String, environment: [String: String], owner: String?, personal: Set<String>, command: TmuxCommand,
        worktree: String, runScript: String?
    ) async throws {
        let names = environment.keys.sorted().joined(separator: " ")
        _ = try await Shell.run(command.executable, command.arguments(["set-option", "-g", "update-environment", names]), cwd: worktree)
        // **The shell this machine's user actually has, not the one the service was started with.**
        // tmux takes `default-shell` from the environment of whoever started the server, which here
        // is Bloom Runner under a service manager, so a pane ran `/bin/sh`: a bare `$`, no profile,
        // and a different shell from the one a run script's pane ended in. With `default-command`
        // left empty, tmux starts `default-shell` as a login shell itself. See `LoginShell`.
        let shell = LoginShell.machinePath()
        _ = try await Shell.run(command.executable, command.arguments(["set-option", "-g", "default-shell", shell]), cwd: worktree)
        // One tmux invocation, so the owner is on the session before anybody can attach to it.
        var arguments = ["new-session", "-d", "-s", session, "-c", worktree]
        // The shell stays after it, so a person can read what happened and carry on in the same
        // terminal, which is what typing the command used to leave them with. Named rather than
        // `$SHELL`, which is the service's, and with the login flag only where it is understood.
        if let runScript {
            let login = ([shell] + LoginShell.loginArguments(for: shell)).map { "'\($0)'" }.joined(separator: " ")
            arguments.append(runScript + "\nexec \(login)\n")
        }
        // `=name:` because an option's target is a pane, and `=name` alone matches no pane.
        if let owner { arguments += [";", "set-option", "-t", "=" + session + ":", ownerOption, owner] }
        if !personal.isEmpty { arguments += [";", "set-option", "-t", "=" + session + ":", personalOption, personal.sorted().joined(separator: " ")] }
        let created = try await Shell.run(command.executable, command.arguments(arguments), cwd: worktree,
                                          env: Shell.environment(extra: environment))
        // Emptied again at once, so a later attach does not copy the attaching client's variables
        // of those names over this session's.
        _ = try await Shell.run(command.executable, command.arguments(["set-option", "-g", "update-environment", ""]), cwd: worktree)
        guard created.ok else { throw RemoteFailure(.unavailable, created.stderr) }
    }

    private func exists(_ session: String, command: TmuxCommand) async throws -> Bool {
        try await Shell.run(command.executable, command.arguments(["has-session", "-t", "=" + session]), cwd: worktree).ok
    }

    private func requireOwner(_ requester: String?, of session: String, command: TmuxCommand) async throws {
        // `-q` answers an unset option as empty, so any failure left is a real one and refuses.
        let shown = try await Shell.run(command.executable, command.arguments(["show-options", "-t", "=" + session + ":", "-qv", Self.ownerOption]),
                                        cwd: worktree)
        guard shown.ok else { throw RemoteFailure(.unavailable, "This terminal could not be checked. Try again.") }
        let owner = shown.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard owner.isEmpty || owner == requester else {
            throw RemoteFailure(.missingAbility, "This terminal belongs to somebody else. Open a terminal of your own.")
        }
    }

    /// POSIX's shape for a variable name. Anything wider could not be named in `update-environment`,
    /// which splits on spaces.
    static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.utf8.first, !(48...57).contains(first) else { return false }
        return name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
    }

    /// Attaches to a terminal, creating its session first when there is none.
    public func attach(
        name: String, environment: [String: String] = [:], owner: String? = nil, personal: Set<String> = [],
        runScript: String? = nil, columns: Int = 80, rows: Int = 24
    ) async throws -> RemoteTerminalAttachment {
        let session = try await ensureSession(name: name, environment: environment, owner: owner, personal: personal,
                                              runScript: runScript)
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

    /// Ends a terminal's shell. Its attachments see their output finish. A person may close only
    /// a terminal they could attach to; `requester` nil is the server, which closes any.
    public func close(name: String, requester: String? = nil) async throws {
        try Self.validate(name: name)
        guard let executable = Shell.which("tmux") else { return }
        let command = TmuxCommand(executable: executable, socketName: socketName, configPath: configurationPath)
        let session = TmuxSessions.sessionName(workspaceID: workspaceID, paneID: name)
        if let requester { try await requireOwner(requester, of: session, command: command) }
        _ = try await Shell.run(executable, command.arguments(["kill-session", "-t", "=" + session]), cwd: stateDirectory)
    }

    /// Ends every shell a person opened, which is what losing access to the workspace means for
    /// them: the shell holds their key and their turn.
    public func closeAll(ownedBy owner: String) async throws {
        try await closeSessions { fields in fields.owner == owner }
    }

    /// Ends every shell holding personal credentials `superseded` picks out, when the workspace
    /// was shared.
    public func closeAll(where superseded: @Sendable (Set<String>) -> Bool) async throws {
        try await closeSessions { fields in !fields.personal.isEmpty && superseded(fields.personal) }
    }

    private func closeSessions(matching: (_ fields: (owner: String, personal: Set<String>)) -> Bool) async throws {
        guard let executable = Shell.which("tmux") else { return }
        let command = TmuxCommand(executable: executable, socketName: socketName, configPath: configurationPath)
        // Tab separated in tmux's own terms would print as `_`, so a `|`, which neither a session
        // name nor a user id nor an agent's name holds.
        let format = "#{session_name}|#{\(Self.ownerOption)}|#{\(Self.personalOption)}"
        let listed = try await Shell.run(executable, command.arguments(["list-sessions", "-F", format]), cwd: stateDirectory)
        guard listed.ok else { return }
        for line in listed.stdout.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, !TmuxSessions.sessions(ofWorkspace: workspaceID, in: [fields[0]]).isEmpty else { continue }
            let personal = Set(fields[2].split(separator: " ").map(String.init))
            guard matching((owner: fields[1], personal: personal)) else { continue }
            _ = try await Shell.run(executable, command.arguments(["kill-session", "-t", "=" + fields[0]]), cwd: stateDirectory)
        }
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

    /// The tmux server this started and is still running. See `WorkspaceRuntime.terminalServerProcessID`.
    public func serverProcessID() async -> Int32? {
        await daemon.serverProcessID
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

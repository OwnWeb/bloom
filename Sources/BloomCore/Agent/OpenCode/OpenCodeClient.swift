import Foundation
import Synchronization

/// One `opencode acp` process, spoken to in ACP JSON-RPC.
///
/// The shape is `GrokClient`'s: a long lived process, requests with replies, a server that asks
/// too, and `session/prompt` held open for the whole turn so its reply is an event. What differs
/// is the dialect, measured on 2.3.2 and written down in `docs/OPENCODE.md`:
///
///   1. **No launch flags.** Permissions come from config, so the mode travels as
///      `OPENCODE_CONFIG_CONTENT` in the environment. See `OpenCodePermission.configContent`.
///   2. **Model and effort are config options**, set with a bare string, and every reply carries
///      the whole option list back.
///   3. **`session/resume` returns no session id**, only the options.
public actor OpenCodeClient {
    public struct Configuration: Sendable {
        public var executable: String
        public var cwd: String
        public var clientName: String
        public var clientVersion: String
        public var environment: [String: String]
        public var permissionMode: PermissionMode?

        /// A nil permission mode injects nothing, which is what model discovery wants.
        public init(
            executable: String = OpenCodeClient.executable,
            cwd: String,
            clientName: String = "Bloom",
            clientVersion: String = "0.0.0",
            environment: [String: String] = Shell.environment(),
            permissionMode: PermissionMode? = nil
        ) {
            self.executable = executable
            self.cwd = cwd
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.environment = environment
            self.permissionMode = permissionMode
        }
    }

    public static let executable = "opencode"
    public static let arguments = ["acp"]

    public static func launch(_ configuration: Configuration) -> AgentLaunch {
        var environment = configuration.environment
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        if let content = configuration.permissionMode.flatMap(OpenCodePermission.configContent) {
            environment["OPENCODE_CONFIG_CONTENT"] = content
        }
        return AgentLaunch(
            executable: configuration.executable,
            arguments: arguments,
            cwd: configuration.cwd,
            environment: environment
        )
    }

    private let configuration: Configuration
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing
    private var process: (any AgentProcessing)?
    private let live = LiveProcess()
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    private var nextRequestID = 1
    private var pending: [ACPRequestID: CheckedContinuation<JSONValue, Error>] = [:]
    /// Prompt requests are not waited on. Their ids live here so the reply becomes an event
    /// rather than resuming a continuation that would pin `send` to the whole turn.
    private var promptIDs: Set<ACPRequestID> = []
    private var handshakeCompleted = false
    private var closedReason: String?
    private var version = ""

    private var stderrTail: [String] = []
    private static let stderrTailLimit = 40

    private let sink = EventFanout<OpenCodeEvent>()

    public init(
        configuration: Configuration,
        makeProcess: @escaping @Sendable (AgentLaunch) -> any AgentProcessing = OpenCodeClient.spawn
    ) {
        self.configuration = configuration
        self.makeProcess = makeProcess
    }

    public static let spawn: @Sendable (AgentLaunch) -> any AgentProcessing = { launch in
        StreamingProcess(
            executable: launch.executable,
            arguments: launch.arguments,
            cwd: launch.cwd,
            environment: launch.environment,
            mergeStderr: false
        )
    }

    public nonisolated var events: AsyncStream<OpenCodeEvent> { sink.stream() }

    public var isRunning: Bool { process?.isRunning ?? false }

    public nonisolated var isProcessAlive: Bool { live.current?.isRunning ?? false }

    public var isClosed: Bool { closedReason != nil }

    public var isReady: Bool { handshakeCompleted }

    public var diagnostics: [String] { stderrTail }

    /// What `initialize` reported as `agentInfo.version`, empty before the handshake.
    public var agentVersion: String { version }

    public static let requestTimeout = Duration.seconds(120)

    // MARK: Lifecycle

    public func start() async throws {
        guard process == nil else { return }

        let process = makeProcess(Self.launch(configuration))
        self.process = process
        live.attach(process)

        let errors = process.errorLines
        let lines = process.lines
        readTask = Task { [weak self] in await self?.readLines(from: lines) }
        stderrTask = Task { [weak self] in await self?.readErrors(from: errors) }

        let result = try await send(
            "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientInfo": .object([
                    "name": .string(configuration.clientName),
                    "version": .string(configuration.clientVersion),
                ]),
                // Empty on purpose. Advertising `fs` or `terminal` makes the agent ask Bloom to
                // read files and run commands; Bloom is not that client.
                "clientCapabilities": .object([:]),
            ])
        )
        version = result["agentInfo"]?["version"]?.stringValue ?? ""
        handshakeCompleted = true
    }

    public func stop() {
        terminateNow()
        finish(reason: "The OpenCode connection was closed")
    }

    public nonisolated func terminateNow() {
        guard let process = live.claimForSignal() else { return }
        process.closeStdin()
        process.terminate()
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, process.isRunning else { return }
            process.kill()
        }
    }

    // MARK: Sending

    @discardableResult
    public func send(
        _ method: String, params: JSONValue?, timeout: Duration = OpenCodeClient.requestTimeout
    ) async throws -> JSONValue {
        if let closedReason { throw ACPClientError.connectionClosed(closedReason) }
        guard process != nil else { throw ACPClientError.notInitialized }

        let id = ACPRequestID.number(nextRequestID)
        nextRequestID += 1

        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.abandon(id, method: method, after: timeout)
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(ACPOutgoing.request(id: id, method: method, params: params))
        }
    }

    private func abandon(_ id: ACPRequestID, method: String, after timeout: Duration) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(
            throwing: ACPClientError.timedOut(
                method: method, seconds: Int(timeout.components.seconds)
            )
        )
    }

    public func notify(_ method: String, params: JSONValue?) {
        write(ACPOutgoing.notification(method: method, params: params))
    }

    public func answer(_ id: ACPRequestID, with result: JSONValue) {
        write(ACPOutgoing.response(id: id, result: result))
    }

    private func write(_ line: String) {
        process?.writeLine(line)
    }

    // MARK: Typed calls

    public func newSession(cwd: String? = nil, mcpServers: [JSONValue] = []) async throws -> OpenCodeSession {
        let result = try await send("session/new", params: sessionParams(
            sessionID: nil, cwd: cwd, mcpServers: mcpServers
        ))
        guard let id = result["sessionId"]?.stringValue, !id.isEmpty else {
            throw ACPClientError.unexpectedResult(method: "session/new")
        }
        return OpenCodeSession(id: id, options: OpenCodeConfigOptions.decode(result))
    }

    /// The reply names no session, so the id asked for is the id resumed. A refusal throws:
    /// `-32602` for an unknown session or one that belongs to another directory.
    public func resumeSession(
        _ sessionID: String, cwd: String? = nil, mcpServers: [JSONValue] = []
    ) async throws -> OpenCodeSession {
        let result = try await send("session/resume", params: sessionParams(
            sessionID: sessionID, cwd: cwd, mcpServers: mcpServers
        ))
        return OpenCodeSession(id: sessionID, options: OpenCodeConfigOptions.decode(result))
    }

    /// `value` is a bare string here. Grok's `{value: …}` wrapper is refused with `-32602`.
    @discardableResult
    public func setConfigOption(
        sessionID: String, configID: String, value: String
    ) async throws -> OpenCodeConfigOptions {
        let result = try await send("session/set_config_option", params: .object([
            "sessionId": .string(sessionID),
            "configId": .string(configID),
            "value": .string(value),
        ]))
        return OpenCodeConfigOptions.decode(result)
    }

    /// Starts a turn without waiting for it. The `session/prompt` reply arrives later as
    /// `.promptCompleted`, and the returned request id is the turn id.
    @discardableResult
    public func beginPrompt(sessionID: String, text: String) throws -> ACPRequestID {
        if let closedReason { throw ACPClientError.connectionClosed(closedReason) }
        guard process != nil else { throw ACPClientError.notInitialized }
        let id = ACPRequestID.number(nextRequestID)
        nextRequestID += 1
        promptIDs.insert(id)
        write(ACPOutgoing.request(
            id: id,
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ])
        ))
        return id
    }

    public func cancel(sessionID: String) {
        notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
    }

    public func closeSession(_ sessionID: String) async {
        _ = try? await send("session/close", params: .object(["sessionId": .string(sessionID)]))
    }

    public func deleteSession(_ sessionID: String) async {
        _ = try? await send("session/delete", params: .object(["sessionId": .string(sessionID)]))
    }

    private func sessionParams(sessionID: String?, cwd: String?, mcpServers: [JSONValue]) -> JSONValue {
        .object(omittingNil: [
            "sessionId": sessionID.map(JSONValue.string),
            "cwd": .string(cwd ?? configuration.cwd),
            "mcpServers": .array(mcpServers),
        ])
    }

    // MARK: Reading

    private func readLines(from lines: AsyncThrowingStream<String, Error>) async {
        do {
            for try await line in lines {
                guard let frame = ACPFrame.decode(line: line) else { continue }
                handle(frame)
            }
            finish(reason: "The OpenCode process ended")
        } catch {
            finish(reason: error.readableMessage)
        }
    }

    private func readErrors(from errors: AsyncStream<String>) async {
        for await line in errors {
            stderrTail.append(line)
            if stderrTail.count > Self.stderrTailLimit { stderrTail.removeFirst() }
        }
    }

    private func handle(_ frame: ACPFrame) {
        switch frame {
        case .response(let id, let result, _):
            if promptIDs.remove(id) != nil {
                sink.yield(.promptCompleted(ACPPromptResult(
                    requestID: id,
                    sessionID: "",
                    stopReason: result["stopReason"]?.stringValue ?? "end_turn",
                    raw: result
                )))
                return
            }
            pending.removeValue(forKey: id)?.resume(returning: result)

        case .failure(let id, let error, _):
            // A turn that cannot reach its provider fails the prompt request itself.
            if promptIDs.remove(id) != nil {
                sink.yield(.promptCompleted(ACPPromptResult(
                    requestID: id,
                    sessionID: "",
                    stopReason: "refusal",
                    raw: .object(["message": .string(error.message)])
                )))
                return
            }
            pending.removeValue(forKey: id)?.resume(throwing: error)

        case .request(let request):
            if let permission = ACPPermissionRequest.decode(request) {
                sink.yield(.permission(permission))
            } else {
                write(ACPOutgoing.failure(
                    id: request.id,
                    code: -32601,
                    message: "Bloom does not implement \(request.method)"
                ))
            }

        case .notification(let notification):
            if notification.method == "session/update",
               let update = ACPSessionUpdate.decode(params: notification.params) {
                sink.yield(.update(update))
            } else {
                sink.yield(.unknown(method: notification.method, raw: notification.raw))
            }

        case .malformed(let raw):
            sink.yield(.unknown(method: "", raw: raw))
        }
    }

    private func finish(reason: String) {
        guard closedReason == nil else { return }
        closedReason = reason

        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: ACPClientError.connectionClosed(reason))
        }
        promptIDs.removeAll()

        sink.yield(.closed(reason: reason))
        sink.finish()
        process = nil
        readTask = nil
        stderrTask = nil
    }
}

private final class LiveProcess: Sendable {
    private struct State {
        var process: (any AgentProcessing)?
        var signalled = false
    }

    private let state = Mutex(State())

    var current: (any AgentProcessing)? { state.withLock(\.process) }

    func attach(_ process: any AgentProcessing) {
        state.withLock { state in
            state.process = process
            state.signalled = false
        }
    }

    func claimForSignal() -> (any AgentProcessing)? {
        state.withLock { state -> (any AgentProcessing)? in
            guard !state.signalled, let process = state.process else { return nil }
            state.signalled = true
            return process
        }
    }
}

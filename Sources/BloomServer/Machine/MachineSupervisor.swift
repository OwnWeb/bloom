import BloomCore
import Foundation

/// runbloom.app's control calls, carried out: the one place that knows which parts of the machine
/// each call touches.
public actor MachineSupervisor: MachineControl {
    private let runtime: WorkspaceRuntime
    private let awake: AwakeController
    private let reporter: MachineReporter
    private let streams: EventStreams
    private let terminals: TerminalConnections
    private let environment: MachineEnvironment
    private let updater: @Sendable (_ version: String, _ sha256: String) async throws -> Void

    public init(
        runtime: WorkspaceRuntime, awake: AwakeController, reporter: MachineReporter, streams: EventStreams,
        terminals: TerminalConnections, environment: MachineEnvironment,
        updater: @escaping @Sendable (_ version: String, _ sha256: String) async throws -> Void
    ) {
        self.runtime = runtime
        self.awake = awake
        self.reporter = reporter
        self.streams = streams
        self.terminals = terminals
        self.environment = environment
        self.updater = updater
    }

    /// Stops turns the way Stop does and blocks the queue with the limit, then reports and lets the
    /// machine go. runbloom.app stops the machine's services thirty seconds later regardless.
    public func stop(limit: String) async {
        let sentence = limit == "kill_switch"
            ? "Cloud workspaces are paused for everyone at the moment."
            : "Your team reached a Cloud workspace limit."
        await runtime.stopForLimit(DeliveryBlock(limit: limit, message: sentence))
        await reporter.changed()
        await awake.nudge()
    }

    public func limitsCleared() async {
        await runtime.limitsCleared()
        await awake.nudge()
    }

    public func revoke(userID: String) async {
        await runtime.revoke(userID: userID)
        await streams.revoke(userID: userID)
        await terminals.revoke(userID: userID)
    }

    public func update(version: String, sha256: String) async throws {
        try await updater(version, sha256)
    }

    public func environmentChanged() async {
        await environment.refresh()
    }
}

/// The team and project environment runbloom.app holds for this workspace, fetched at start, at
/// every wake that restarts the server, and when runbloom.app says it changed.
///
/// **In memory only.** It reaches scripts and services through their process environment and
/// nothing else; a script that writes it into `.env` has made that choice itself.
public actor MachineEnvironment {
    private let fetch: @Sendable () async throws -> [String: String]
    private(set) public var values: [String: String] = [:]
    private var onChange: (@Sendable ([String: String]) async -> Void)?

    public init(fetch: @escaping @Sendable () async throws -> [String: String]) {
        self.fetch = fetch
    }

    public func observe(_ onChange: @escaping @Sendable ([String: String]) async -> Void) {
        self.onChange = onChange
    }

    /// Fetches again, keeping what it had when runbloom.app cannot be reached.
    @discardableResult
    public func refresh() async -> [String: String] {
        guard let fresh = try? await fetch() else { return values }
        let changed = fresh != values
        values = fresh
        if changed { await onChange?(fresh) }
        return fresh
    }
}

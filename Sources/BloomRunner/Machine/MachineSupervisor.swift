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
    private let secret: WorkspaceSecret
    private let revocations: Revocations
    private let updater: @Sendable (_ version: String, _ sha256: String, _ tag: String?, _ downloadURL: String?) async throws -> Void

    public init(
        runtime: WorkspaceRuntime, awake: AwakeController, reporter: MachineReporter, streams: EventStreams,
        terminals: TerminalConnections, environment: MachineEnvironment, secret: WorkspaceSecret,
        revocations: Revocations,
        updater: @escaping @Sendable (_ version: String, _ sha256: String, _ tag: String?, _ downloadURL: String?) async throws -> Void
    ) {
        self.runtime = runtime
        self.awake = awake
        self.reporter = reporter
        self.streams = streams
        self.terminals = terminals
        self.environment = environment
        self.secret = secret
        self.revocations = revocations
        self.updater = updater
    }

    /// Stops turns the way Stop does and blocks the queue with the limit, then reports and lets the
    /// machine go. runbloom.app stops the machine's services thirty seconds later regardless.
    public func stop(limit: String) async {
        let sentence = limit == "kill_switch"
            ? "Bloom Cloud workspaces are paused for everyone at the moment."
            : "Your team reached a Bloom Cloud workspace limit."
        await runtime.stopForLimit(DeliveryBlock(limit: limit, message: sentence))
        await reporter.changed()
        await awake.nudge()
    }

    public func limitsCleared() async {
        await runtime.limitsCleared()
        await awake.nudge()
    }

    public func revoke(userID: String) async {
        // First, so nothing they hold can open anything again while the rest closes.
        await revocations.revoke(userID)
        await runtime.revoke(userID: userID)
        await streams.revoke(userID: userID)
        await terminals.revoke(userID: userID)
    }

    public func shared() async {
        await runtime.becameShared()
    }

    public func secretRotated() async {
        secret.reload()
    }

    public func update(version: String, sha256: String, tag: String?, downloadURL: String?) async throws {
        try await updater(version, sha256, tag, downloadURL)
    }

    public func environmentChanged() async {
        await environment.refresh()
    }
}

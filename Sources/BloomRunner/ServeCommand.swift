import AsyncHTTPClient
import BloomCore
import Foundation
import Hummingbird
import ServiceLifecycle

/// `bloom-runner serve`: everything a machine runs, put together once.
///
/// The order matters in three places. The first summary goes before setup starts, because that
/// summary is what makes runbloom.app hand out tokens, and setup output is worth watching live.
/// The HTTP server is listening before setup starts for the same reason. And on the way out the
/// machine reports and closes streams before anything stops, so a limit or an update that ends
/// the process still leaves runbloom.app knowing where things stood.
public enum ServeCommand {
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        let configuration = try MachineConfiguration.load(environment: environment)
        let layout = MachineLayout.from(environment: environment)
        try FileManager.default.createDirectory(atPath: layout.dataDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let localSecret = try writeLocalSecret(in: layout.dataDirectory)

        let store = try Store(path: layout.databasePath)
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        // Only the secret is taken from a rewritten file. Everything else in it is fixed for the
        // life of the workspace, and a file naming another workspace is not this machine's.
        let secret = WorkspaceSecret(configuration.workspaceSecret) {
            let fresh = try MachineConfiguration.load(environment: environment)
            guard fresh.workspaceID == configuration.workspaceID else {
                throw MachineConfigurationError("workspace.json now names another workspace.")
            }
            return fresh.workspaceSecret
        }
        let client = RunbloomClient(baseURL: configuration.baseURL, workspaceID: configuration.workspaceID, secret: secret, http: http)
        let gate = RunbloomTurns(client: client)
        let workspace = try await RemoteMachineWorkspace.ensure(
            store: store, id: configuration.workspaceID, name: configuration.name, repository: configuration.repository,
            path: layout.worktree, branch: configuration.branch, baseBranch: configuration.baseBranch
        )
        let version = RunnerVersion.current
        let binDirectory = layout.dataDirectory + "/bin"
        let runtime = WorkspaceRuntime(
            store: store, workspaceID: workspace.id, gate: gate,
            makeRunner: { session, path, store, environment, bridge in
                // Every agent process can find the gh wrapper first and says which chat it is, which
                // is how its git credentials are asked for as whoever's turn it is running.
                var extra = environment
                extra["BLOOM_CHAT_ID"] = session.id.rawValue
                extra["BLOOM_REPOSITORY"] = configuration.repository
                extra["BLOOM_DATA_DIR"] = layout.dataDirectory
                extra["BLOOM_RUNNER_PORT"] = String(layout.serverPort)
                extra["PATH"] = binDirectory + ":" + (environment["PATH"] ?? Shell.environment()["PATH"] ?? "/usr/bin:/bin")
                return RemoteRunnerFactory.live(session, path, store, extra, bridge)
            },
            publishing: RemotePublishing { turnID in
                try await client.gitCredentials(repository: configuration.repository, operation: .write, turnID: turnID).token
            },
            // Short and under the data directory, because a Unix socket path has a length limit and
            // only the machine's own user should reach it. The shim is bloom-bridge beside this binary.
            bridgeSocketPath: layout.dataDirectory + "/bridge.sock"
        )
        let host: any MachineHost = SpriteMachineHost.isAvailable ? SpriteMachineHost(http: http) : LocalMachineHost()
        let delivery = ReportDelivery(sender: .init(client: client))
        let reporter = MachineReporter(runtime: runtime, store: store, delivery: delivery, host: host, version: version)
        let awake = AwakeController(host: host, runtime: runtime, reporter: reporter)
        let machineEnvironment = MachineEnvironment { try await client.environment() }
        let keys = KeySet.live(url: configuration.jwksURL, client: http)
        let verifier = TokenVerifier(issuer: configuration.issuer, workspaceID: configuration.workspaceID, keys: keys,
                                     revocations: Revocations(store: store))

        await runtime.observeActivity { event in
            switch event {
            case .turnStarted(_, let turnID, let author, let agent):
                if let turnID { await reporter.record(.turnStarted(turnID: turnID, userID: author?.userID, agent: agent, at: Date())) }
                await reporter.changed()
            case .turnFinished(_, let turnID):
                // runbloom.app pairs a finish with its start by the turn, so a turn nobody
                // registered (a subagent's report) is reported as neither.
                if let turnID { await reporter.record(.turnFinished(turnID: turnID, at: Date())) }
                await reporter.changed()
            case .chatIdle:
                await reporter.changed()
            case .setupStarted:
                await reporter.record(.setupStarted(at: Date()))
                await reporter.changed()
            case .setupStep:
                await reporter.changed()
            case .setupFinished(let succeeded):
                await reporter.record(.setupFinished(succeeded: succeeded, at: Date()))
                await reporter.changed()
            case .humanInput:
                break
            case .workspaceChanged:
                await reporter.changed()
                return
            case .connectionsChanged(let open):
                await awake.connectionsChanged(open: open)
                await reporter.changed(slow: true)
                return
            }
            await awake.nudge()
        }

        try await runtime.start()
        await reporter.postSummaryNow()
        await machineEnvironment.refresh()

        let streams = EventStreams()
        let terminals = TerminalConnections()
        let supervisor = MachineSupervisor(
            runtime: runtime, awake: awake, reporter: reporter, streams: streams, terminals: terminals,
            environment: machineEnvironment, secret: secret, revocations: verifier.revocations, updater: { version, sha256, tag in try MachineUpdate.start(version: version, sha256: sha256, tag: tag) }
        )
        let server = WorkspaceHTTPServer(dependencies: .init(
            runtime: runtime, verifier: verifier, gate: gate, control: supervisor, store: store,
            allowedOrigins: configuration.allowedOrigins, version: version, streams: streams, terminals: terminals,
            gitCredentials: .init(secret: localSecret, repository: configuration.repository) { repository, operation, turn in
                try await client.gitCredentials(repository: repository, operation: operation, turnID: turn)
            }
        ))

        let services = ServiceSupervisor(layout: layout)
        let caddy = CaddySupervisor(layout: layout, publicURL: configuration.publicURL)
        let setup = MachineSetup(runtime: runtime, store: store, configuration: configuration, layout: layout,
                                 environment: machineEnvironment, services: services)
        await machineEnvironment.observe { _ in await setup.restartServices() }
        // Caddy first, so the machine's URL answers while setup runs; a machine without it still
        // serves Bloom Runner on its own port, which is what development on a Mac does.
        do {
            try await caddy.start()
        } catch {
            FileHandle.standardError.write(Data("bloom-runner: \(error)\n".utf8))
        }

        let measurements = WorktreeMeasurements(runtime: runtime, reporter: reporter)
        await awake.whenWaking { await machineEnvironment.refresh() }
        await awake.start()
        await measurements.start()
        // After the first summary and with the server about to listen, so setup can be watched live.
        let setupRun = Task { await setup.run() }
        // An update waits for this file to go: deleting it once listening is how a new release says
        // it came up, which works whether or not the script that restarted the service survived it.
        let application = server.application(port: layout.serverPort) { _ in
            try? FileManager.default.removeItem(atPath: environment["BLOOM_UPDATE_MARKER"] ?? "/var/tmp/bloom-update-pending")
        }

        // SIGTERM: a limit's grace ran out, an update is restarting the service, or the machine is
        // being deleted. The wind down runs before the HTTP server stops, not after: the server's
        // graceful shutdown waits for every request to finish, and an event stream or a terminal
        // never does, so a machine with one client connected never got as far as reporting.
        let windDown = WindDown {
            note("stopping: stopping turns, reporting to runbloom.app and closing streams")
            // Setup first, filed as interrupted, so nothing it would start begins now.
            setupRun.cancel()
            await setupRun.value
            await measurements.stop()
            // Turns before the report, so the last usage report has every turn finishing in it.
            // This also closes every event stream.
            await runtime.shutdown()
            await terminals.closeAll()
            await services.stopAll()
            await caddy.stop()
            await awake.shutdown()
        }
        // A service group shuts its services down in reverse order, so the wind down goes first.
        let group = ServiceGroup(configuration: .init(
            services: [.init(service: application), .init(service: windDown, successTerminationBehavior: .gracefullyShutdownGroup)],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: application.logger
        ))
        try await group.run()
        await delivery.shutdown()
        try await http.shutdown()
        note("stopped")
    }

    static func note(_ line: String) {
        FileHandle.standardError.write(Data("bloom-runner: \(line)\n".utf8))
    }

    /// The secret the git credential helper proves itself to the loopback route with. New on every
    /// start, so a copy taken from an earlier run is worth nothing.
    static func writeLocalSecret(in directory: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        let path = directory + "/local-secret"
        guard FileManager.default.createFile(atPath: path, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw MachineConfigurationError("Cannot write \(path).")
        }
        return secret
    }
}

/// Waits for the service group to begin shutting down, then does the machine's own shutdown.
struct WindDown: Service {
    let work: @Sendable () async -> Void

    func run() async throws {
        // Throws only when the group is cancelled, which is a shutdown too.
        try? await gracefulShutdown()
        await work()
    }
}

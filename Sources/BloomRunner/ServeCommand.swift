import AsyncHTTPClient
import BloomCore
import BloomProtocol
import Foundation
import Hummingbird
import ServiceLifecycle
import Synchronization

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
        // The user an agent, a terminal, a script and a service run as, or nil on a machine whose
        // provisioning has not made one, which runs them as this process's user as it always did.
        // See `MachineSandbox` and `Tools/provision-sandbox.sh`.
        let sandbox = MachineSandbox.available()
        FileHandle.standardError.write(Data((sandbox.map { "bloom-runner: agents run as \($0.user)\n" }
            ?? "bloom-runner: no sandbox user on this machine, so agents run as this process does\n").utf8))
        let binDirectory = layout.dataDirectory + "/bin"
        // Who may be addressed, pulled from runbloom.app and refetched on a miss so that somebody
        // who joined the team this morning is addressable this afternoon. See `MachineMembers`.
        let members = MachineMembers { try await client.members() }
        // The word that somebody was addressed, which is what lets runbloom.app mail them. Its own
        // sender rather than a fold into the usage queue, because it causes mail: see
        // `AddressedReporter`.
        let addressedReporter = AddressedReporter(store: store) { try await client.reportAddressed($0) }
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
                return RemoteRunnerFactory.make(session, path, store, extra, bridge, sandbox: sandbox)
            },
            publishing: RemotePublishing { turnID in
                try await client.gitCredentials(repository: configuration.repository, operation: .write, turnID: turnID).token
            },
            // Short and under the data directory, because a Unix socket path has a length limit and
            // only the machine's own user should reach it. The shim is bloom-bridge beside this binary.
            bridgeSocketPath: layout.dataDirectory + "/bridge.sock",
            runsSetup: configuration.runsSetup,
            briefing: BridgeBriefing.machine(
                publicURL: configuration.publicURL, appPort: layout.appPort, reservedPorts: layout.reservedPorts
            ),
            lookUpMember: { await members.look(up: $0) },
            listMembers: { await members.all() },
            addressed: { _ in await addressedReporter.start() },
            createCloudWorkspace: { await client.createCloudWorkspace($0) },
            peers: RunbloomPeers.peers(client: client, http: http)
        )
        let host: any MachineHost = SpriteMachineHost.isAvailable ? SpriteMachineHost(http: http) : LocalMachineHost()
        // What the machine says about its own reporting goes two ways here, because the two readers
        // are different people: to the workspace record, so anybody looking at the workspace sees
        // that what they are doing is not being recorded, and to the log with the queue's depth,
        // for whoever reads a machine afterwards. The third reader is runbloom.app, which is told
        // about shedding by `MachineReporter` in the next report it can send.
        let shedSoFar = Mutex(0)
        let delivery = ReportDelivery(sender: .init(client: client), observer: { status in
            await runtime.reportingChanged(status.record)
            let newlyShed = shedSoFar.withLock { shed -> Int in
                defer { shed = status.shed }
                return status.shed - shed
            }
            if newlyShed > 0 {
                note("shed \(newlyShed) unsent usage report(s); \(status.queued) queued, \(status.queuedBytes) bytes")
            }
            if let since = status.unreachableSince {
                // Not "unreachable": the three things that reach here are a network that answered
                // nothing, a server that erred, and a machine that was asleep, and only the first
                // is what that word means. What is true of all of them is that nothing has been
                // recorded since.
                note("nothing reported to runbloom.app since \(WireDate.string(from: since)); "
                     + "\(status.queued) report(s) queued, \(status.queuedBytes) bytes")
            }
        })
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
        // Whatever the last run could not deliver, including the case this exists for: a machine
        // that stopped between writing the message and telling runbloom.app about it.
        await addressedReporter.start()
        await reporter.postSummaryNow()
        await machineEnvironment.refresh()

        let streams = EventStreams()
        let terminals = TerminalConnections()
        let supervisor = MachineSupervisor(
            runtime: runtime, awake: awake, reporter: reporter, streams: streams, terminals: terminals,
            environment: machineEnvironment, secret: secret, revocations: verifier.revocations, updater: { version, sha256, tag, downloadURL in
                try MachineUpdate.start(version: version, sha256: sha256, tag: tag, downloadURL: downloadURL)
            }
        )
        // The supervisor's own states, on the workspace record, because a service that never
        // started is otherwise a sentence held in this process's memory and reachable only through
        // a preview page that a project's own proxy can make unreachable. See `ServiceRecord`.
        let services = ServiceSupervisor(layout: layout, observer: { [weak runtime] statuses in
            await runtime?.servicesChanged(statuses.map {
                ServiceRecord(name: $0.name, state: $0.state.rawValue, restarts: $0.restarts,
                              message: $0.message, isHTTP: $0.isHTTP)
            })
        })
        let server = WorkspaceHTTPServer(dependencies: .init(
            runtime: runtime, verifier: verifier, gate: gate, control: supervisor, store: store,
            allowedOrigins: configuration.allowedOrigins, version: version, streams: streams, terminals: terminals,
            gitCredentials: .init(secret: localSecret, repository: configuration.repository) { repository, operation, turn in
                try await client.gitCredentials(repository: repository, operation: operation, turnID: turn)
            },
            services: { await services.status },
            appPort: layout.appPort,
            reservedPorts: layout.reservedPorts.map(\.port)
        ))

        let caddy = CaddySupervisor(layout: layout, publicURL: configuration.publicURL)
        let setup = MachineSetup(runtime: runtime, store: store, configuration: configuration, layout: layout,
                                 environment: machineEnvironment, services: services)
        await machineEnvironment.observe { _ in await setup.restartServices() }
        // `stop_setup` reaches the machine's own setup through here; one run by hand is the
        // runtime's own to stop. See `MachineSetup.stop(by:)`.
        await runtime.setSetupStopper { name in await setup.stop(by: name) }
        await runtime.setSetupRerunner { await setup.rerunSetup() }
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
        // The opening prompt, when an agent created this workspace with one, after setup so it runs
        // on an installed project; after a failed setup too, so the person sees why. See
        // `OpeningHandoff`.
        let openings = OpeningHandoff(client: client, runtime: runtime)
        let setupRun = Task {
            await setup.run()
            if !Task.isCancelled { await openings.run() }
        }
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

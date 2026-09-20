import Foundation
import HTTPTypes
import Hummingbird
import Synchronization
import Testing
@testable import BloomCore
@testable import BloomRunner

@Suite("The project's services, supervised")
struct ServiceSupervisorTests {
    static let fast = ServiceSupervisor.Tuning(
        readinessDeadline: .seconds(20), readinessInterval: .milliseconds(100),
        backoff: RestartBackoff(initial: .milliseconds(100), maximum: .milliseconds(400), stableAfter: .seconds(30)),
        stopGrace: .seconds(1)
    )

    func supervisor(appPort: Int = 3000, tuning: ServiceSupervisor.Tuning = Self.fast) throws -> (ServiceSupervisor, String) {
        let root = try SetupTestSupport.directory("services")
        let layout = MachineLayout(dataDirectory: root + "/data", worktree: root, appPort: appPort)
        return (ServiceSupervisor(layout: layout, tuning: tuning), root)
    }

    static func state(_ supervisor: ServiceSupervisor, _ name: String) async -> ServiceSupervisor.State? {
        await supervisor.status.first { $0.name == name }?.state
    }

    @Test("a service waits for its dependency's ready check, which a 5xx does not pass")
    func dependencyOrderAndReadiness() async throws {
        let answering = Mutex(false)
        let listener = try await LocalListener.start { router in
            router.get("/up") { _, _ -> Response in
                let ready = answering.withLock { $0 }
                return Response(status: ready ? .ok : .serviceUnavailable)
            }
        }
        let (supervisor, root) = try supervisor(appPort: listener.port)
        await supervisor.start([
            .init(name: "vite", command: "date +%s%N > vite.started; exec sleep 60", dependsOn: ["app"]),
            .init(name: "app", command: "echo app output; exec sleep 60", http: true, ready: "http:/up"),
        ], environment: ProcessInfo.processInfo.environment)

        #expect(await SetupTestSupport.eventually { await Self.state(supervisor, "app") == .starting })
        #expect(await Self.state(supervisor, "vite") == .waiting)
        #expect(await supervisor.status.first { $0.name == "vite" }?.message == "Waiting for app.")
        try await Task.sleep(for: .milliseconds(600))
        #expect(!FileManager.default.fileExists(atPath: root + "/vite.started"))

        answering.withLock { $0 = true }
        #expect(await SetupTestSupport.eventually { await Self.state(supervisor, "app") == .running })
        #expect(await SetupTestSupport.eventually { FileManager.default.fileExists(atPath: root + "/vite.started") })
        #expect(await SetupTestSupport.eventually { await Self.state(supervisor, "vite") == .running })
        #expect(SetupTestSupport.read(supervisor.logPath(for: "app")).contains("app output"))

        await supervisor.stopAll()
        await listener.stop()
    }

    @Test("a ready check that never passes is reported, and its dependents are not started")
    func readinessGivesUp() async throws {
        let port = try await FreePort.pick()
        var tuning = Self.fast
        tuning.readinessDeadline = .milliseconds(800)
        let (supervisor, root) = try supervisor(appPort: port, tuning: tuning)
        await supervisor.start([
            .init(name: "app", command: "exec sleep 60", ready: "http:/up"),
            .init(name: "worker", command: "touch worker.started; exec sleep 60", dependsOn: ["app"]),
        ], environment: ProcessInfo.processInfo.environment)

        #expect(await SetupTestSupport.eventually { await Self.state(supervisor, "app") == .notReady })
        let message = await supervisor.status.first?.message ?? ""
        #expect(message.contains("http://127.0.0.1:\(port)/up did not answer"))
        #expect(await Self.state(supervisor, "worker") == .waiting)
        #expect(!FileManager.default.fileExists(atPath: root + "/worker.started"))
        await supervisor.stopAll()
    }

    @Test("a crashed service is started again, with its restarts counted")
    func restartAfterCrash() async throws {
        let (supervisor, root) = try supervisor()
        await supervisor.start([
            .init(name: "flaky", command: "echo run >> runs; exit 1"),
        ], environment: ProcessInfo.processInfo.environment)

        #expect(await SetupTestSupport.eventually { SetupTestSupport.read(root + "/runs").split(separator: "\n").count >= 3 })
        let status = try #require(await supervisor.status.first)
        #expect(status.restarts >= 2)
        #expect(SetupTestSupport.read(supervisor.logPath(for: "flaky")).contains("[bloom] Exited with status 1."))
        await supervisor.stopAll()
        let runs = SetupTestSupport.read(root + "/runs").split(separator: "\n").count
        try await Task.sleep(for: .milliseconds(800))
        #expect(SetupTestSupport.read(root + "/runs").split(separator: "\n").count == runs)
        #expect(await Self.state(supervisor, "flaky") == .stopped)
    }

    @Test("stopping kills the whole process group, including children that ignore SIGTERM")
    func stopKillsChildren() async throws {
        let (supervisor, root) = try supervisor()
        // `trap '' TERM` is inherited by the background child, so only SIGKILL after the grace
        // period ends either of them.
        await supervisor.start([
            .init(name: "stubborn", command: "trap '' TERM; sleep 120 & echo $! > child.pid; echo $$ > shell.pid; wait"),
        ], environment: ProcessInfo.processInfo.environment)

        #expect(await SetupTestSupport.eventually { !SetupTestSupport.read(root + "/child.pid").isEmpty && !SetupTestSupport.read(root + "/shell.pid").isEmpty })
        let child = try #require(Int32(SetupTestSupport.read(root + "/child.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        let shell = try #require(Int32(SetupTestSupport.read(root + "/shell.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(SetupTestSupport.isAlive(child))

        let began = ContinuousClock.now
        await supervisor.stopAll()
        #expect(ContinuousClock.now - began < .seconds(8))
        #expect(await SetupTestSupport.eventually(timeout: .seconds(5)) { !SetupTestSupport.isAlive(child) && !SetupTestSupport.isAlive(shell) })
    }

    @Test("restarting with a new environment runs every service again with it")
    func restartWithEnvironment() async throws {
        let (supervisor, root) = try supervisor()
        var environment = ProcessInfo.processInfo.environment
        environment["GREETING"] = "first"
        await supervisor.start([
            .init(name: "echo", command: "echo \"$GREETING\" >> greetings; exec sleep 60"),
        ], environment: environment)
        #expect(await SetupTestSupport.eventually { SetupTestSupport.read(root + "/greetings") == "first\n" })

        environment["GREETING"] = "second"
        await supervisor.restartAll(environment: environment)
        #expect(await SetupTestSupport.eventually { SetupTestSupport.read(root + "/greetings") == "first\nsecond\n" })
        #expect(await supervisor.status.first?.restarts == 0)
        await supervisor.stopAll()
    }

    @Test("the backoff doubles to its ceiling and starts again after a stable run")
    func backoff() {
        var backoff = RestartBackoff.standard
        let short = Duration.seconds(2)
        let first = backoff.delay(afterRunningFor: short)
        let second = backoff.delay(afterRunningFor: short)
        let third = backoff.delay(afterRunningFor: short)
        #expect([first, second, third] == [.seconds(1), .seconds(2), .seconds(4)])
        for _ in 0..<10 { _ = backoff.delay(afterRunningFor: short) }
        let ceiling = backoff.delay(afterRunningFor: short)
        #expect(ceiling == .seconds(60))
        let afterStableRun = backoff.delay(afterRunningFor: .seconds(61))
        #expect(afterStableRun == .seconds(1))
    }

    @Test("a service name cannot leave the log directory")
    func logFileName() {
        #expect(ServiceSupervisor.fileName("../etc/passwd") == "-.-etc-passwd")
        #expect(ServiceSupervisor.fileName("queue worker") == "queue-worker")
    }
}

/// The port contract, said when it is broken rather than only in a variable nobody read.
@Suite("A service that cannot have its port")
struct ReservedPortAdviceTests {
    static let reserved = [(port: 8080, holder: "the preview proxy"), (port: 8081, holder: "Bloom Runner itself")]

    /// The real output from `there-there.app`'s `app` service, which crash-looped every second
    /// against Bloom Runner's own port with nobody told why.
    @Test("a collision with one of ours names the port and what has it")
    func collisionWithOurs() throws {
        let output = """
        WARN  Unable to respect the `PHP_CLI_SERVER_WORKERS` environment variable without the `--no-reload` flag.
        Failed to listen on 127.0.0.1:8081 (reason: Address already in use)
        [bloom] Exited with status 1. Starting again in 1 s.
        """
        let advice = try #require(ServiceSupervisor.portAdvice(in: output, reserved: Self.reserved))

        #expect(advice.contains("8081"))
        #expect(advice.contains("Bloom Runner itself"))
        #expect(advice.contains("BLOOM_RESERVED_PORTS"))
        #expect(advice.contains("BLOOM_APP_PORT"))
    }

    /// Two of a project's own services fighting over a port is not something Bloom knows about, and
    /// a machine that explained it would be making things up.
    @Test("a collision that is not with one of ours is not ours to explain")
    func collisionWithSomethingElse() {
        let output = "Failed to listen on 127.0.0.1:5173 (reason: Address already in use)"

        #expect(ServiceSupervisor.portAdvice(in: output, reserved: Self.reserved) == nil)
    }

    @Test("a service that exited for any other reason gets no port advice")
    func ordinaryFailure() {
        #expect(ServiceSupervisor.portAdvice(in: "PHP Fatal error: unexpected end of file", reserved: Self.reserved) == nil)
        #expect(ServiceSupervisor.portAdvice(in: "", reserved: Self.reserved) == nil)
    }
}

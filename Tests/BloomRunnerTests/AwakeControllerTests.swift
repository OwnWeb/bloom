import BloomProtocol
import Foundation
import Synchronization
import Testing
@testable import BloomCore
@testable import BloomRunner

@Suite("Holding the machine awake, and letting it sleep")
struct AwakeControllerTests {
    struct Fixture {
        let store: Store
        let runtime: WorkspaceRuntime
        let host: RecordingHost
        let box: SentBox
        let reporter: MachineReporter
        let awake: AwakeController
        let clock: TestClock
    }

    func fixture(
        capabilities: [String] = [],
        capabilitiesProvider: (@Sendable () -> [String])? = nil,
        started: Bool = true
    ) async throws -> Fixture {
        let store = try Store(path: NSTemporaryDirectory() + "bloom-awake-\(UUID().uuidString).sqlite")
        let path = NSTemporaryDirectory() + "bloom-awake-worktree-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let workspace = try await RemoteMachineWorkspace.ensure(store: store, id: "01k5a7d3v1x0m8n2q4r6s9t0wy", name: "Queue retries",
                                                                 repository: "spatie/bloom", path: path, branch: "queue-retries", baseBranch: "main")
        let runtime = WorkspaceRuntime(store: store, workspaceID: workspace.id, makeRunner: { _, _, _, _, _, _ in NeverRunner() },
                                       installedAgents: { [.claudeCode] }, models: { _ in [] })
        if started { try await runtime.start() }
        let host = RecordingHost()
        let box = SentBox()
        let delivery = ReportDelivery(sender: .init(summary: { box.append("summary", $0) }, usage: { box.append("usage", $0) }))
        let clock = TestClock(Date())
        let reporter = MachineReporter(
            runtime: runtime, store: store, delivery: delivery, host: host, version: "1.0.0",
            capabilities: capabilities, capabilitiesProvider: capabilitiesProvider, now: clock.reading
        )
        let awake = AwakeController(host: host, runtime: runtime, reporter: reporter, now: clock.reading)
        return Fixture(store: store, runtime: runtime, host: host, box: box, reporter: reporter, awake: awake, clock: clock)
    }

    @Test("human input takes a hold, and the lease running out releases it in order: reports, streams, hold")
    func inputHoldsThenReleases() async throws {
        let fixture = try await fixture()
        await fixture.runtime.noteHumanInput(from: MessageAuthor(userID: "01k5a7c2b0z9y8x7w6v5t4s3rq", name: "Freek"))
        await fixture.awake.evaluate()
        #expect(fixture.host.log.withLock { $0 } == ["hold"])

        let stream = try await fixture.runtime.openEvents(for: RemoteCaller.server, after: nil)
        fixture.clock.advance(by: 16 * 60)
        await fixture.awake.evaluate()
        #expect(fixture.host.log.withLock { $0 } == ["hold", "release"])

        // The stream was told before the hold went.
        var sawSleeping = false
        for await event in stream where event == .sleeping { sawSleeping = true }
        #expect(sawSleeping)

        let sent = fixture.box.sent.withLock { $0 }
        let lastSummary = try #require(sent.last { $0.kind == "summary" })
        let summary = try JSONSerialization.jsonObject(with: lastSummary.body) as? [String: Any]
        #expect(summary?["awake"] as? Bool == false)
        let usage = try #require(sent.last { $0.kind == "usage" })
        let report = try WireJSON.decode(UsageReport.self, from: usage.body)
        #expect(report.events.map(\.kind).suffix(1) == ["released"])
        #expect(report.events.contains { $0.kind == "awake" && $0.reason == "human_input" })
        await fixture.runtime.shutdown()
    }

    @Test("an open stream alone does not hold the machine")
    func streamsDoNotHold() async throws {
        let fixture = try await fixture()
        _ = try await fixture.runtime.openEvents(for: RemoteCaller.server, after: nil)
        await fixture.awake.connectionsChanged(open: 1)
        #expect(fixture.host.log.withLock { $0 }.isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test("setup holds the machine until it finishes")
    func setupHolds() async throws {
        let fixture = try await fixture()
        await fixture.runtime.setupStepStarted("prepare")
        await fixture.awake.evaluate()
        #expect(fixture.host.log.withLock { $0 } == ["hold"])
        await fixture.runtime.setupFinished(succeeded: true)
        await fixture.awake.evaluate()
        #expect(fixture.host.log.withLock { $0 } == ["hold", "release"])
        await fixture.runtime.shutdown()
    }

    @Test("a summary revision is newer than the last one even after the server starts again")
    func revisionsSurviveRestarts() async throws {
        let fixture = try await fixture()
        try await fixture.store.setSetting(MachineReporter.revisionKey, String(Int64.max / 2))
        await fixture.reporter.postSummaryNow()
        _ = await fixture.reporter.flush(timeout: .seconds(2))
        let body = try #require(fixture.box.sent.withLock { $0 }.last { $0.kind == "summary" }?.body)
        let summary = try WireJSON.decode(RemoteSummary.self, from: body)
        #expect(summary.revision == Int64.max / 2 + 1)
        #expect(summary.title == "Queue retries")
        #expect(summary.state == "setting_up")
        await fixture.runtime.shutdown()
    }

    @Test("a summary advertises only the single runtime-proved credential capability")
    func summaryCarriesCapability() async throws {
        let capability = PersonBoundRuntimeFoundation.capability
        let fixture = try await fixture(capabilities: [capability])
        await fixture.reporter.postSummaryNow()
        _ = await fixture.reporter.flush(timeout: .seconds(2))
        let body = try #require(fixture.box.sent.withLock { $0 }.last { $0.kind == "summary" }?.body)
        let summary = try WireJSON.decode(RemoteSummary.self, from: body)
        #expect(summary.bloomRunnerCapabilities == [capability])
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("\"bloom_runner_capabilities\":[\"person_bound_github_credentials_v1\"]"))
        await fixture.runtime.shutdown()
    }

    @Test("a runtime failure removes a previously advertised capability")
    func summaryReevaluatesCapabilities() async throws {
        let healthy = Mutex(true)
        let capability = PersonBoundRuntimeFoundation.capability
        let fixture = try await fixture(capabilitiesProvider: {
            healthy.withLock { $0 } ? [capability] : []
        })
        await fixture.reporter.postSummaryNow()
        healthy.withLock { $0 = false }
        await fixture.reporter.postSummaryNow()
        _ = await fixture.reporter.flush(timeout: .seconds(2))

        let bodies = fixture.box.sent.withLock { $0.filter { $0.kind == "summary" }.map(\.body) }
        #expect(bodies.count == 2)
        let body = try #require(bodies.last)
        let last = try WireJSON.decode(RemoteSummary.self, from: body)
        #expect(last.bloomRunnerCapabilities.isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test("a machine that is stopping still advertises what it could do while it served")
    func windingDownKeepsCapabilities() async throws {
        // The model gateway stops before the last summary, and a summary without its capability
        // made runbloom.app revoke the machine's model grants, so the next process's queued turn
        // was refused with 403 model_grant_invalid.
        let gatewayListening = Mutex(true)
        let fixture = try await fixture(capabilitiesProvider: {
            gatewayListening.withLock { $0 } ? [ModelGateway.capability] : []
        })
        await fixture.reporter.postSummaryNow()
        await fixture.reporter.windingDown()
        gatewayListening.withLock { $0 = false }
        await fixture.reporter.setDiff(RemoteSummary.Diff(files: 1, additions: 2, deletions: 0))
        await fixture.reporter.postSummaryNow()
        _ = await fixture.reporter.flush(timeout: .seconds(30))

        let bodies = fixture.box.sent.withLock { $0.filter { $0.kind == "summary" }.map(\.body) }
        #expect(bodies.count == 2)
        let last = try WireJSON.decode(RemoteSummary.self, from: try #require(bodies.last))
        #expect(last.diff.files == 1)
        #expect(last.bloomRunnerCapabilities == [ModelGateway.capability])
        await fixture.runtime.shutdown()
    }

    @Test("the first summary can be sent and seen through before the runtime restores its queue")
    func firstSummaryLandsBeforeStart() async throws {
        let fixture = try await fixture(capabilities: [ModelGateway.capability], started: false)
        let delivered = await fixture.reporter.postSummaryAndWait(timeout: .seconds(30))
        #expect(delivered)
        // Already with runbloom.app when this returns, not queued behind a backoff.
        let body = try #require(fixture.box.sent.withLock { $0 }.last { $0.kind == "summary" }?.body)
        let summary = try WireJSON.decode(RemoteSummary.self, from: body)
        #expect(summary.bloomRunnerCapabilities == [ModelGateway.capability])
        #expect(summary.title == "Queue retries")
        await fixture.runtime.shutdown()
    }
}

final class RecordingHost: MachineHost {
    let log = Mutex<[String]>([])
    func hold(for duration: Duration) async throws { log.withLock { if $0.last != "hold" { $0.append("hold") } } }
    func release() async throws { log.withLock { $0.append("release") } }
    func usageSample() -> MachineUsageReading? {
        MachineUsageReading(cpuSeconds: 12.5, memoryUsedBytes: 1_073_741_824, diskUsedBytes: 5_000_000_000, bootID: "boot-1")
    }
}

final class SentBox: Sendable {
    let sent = Mutex<[(kind: String, body: Data)]>([])
    func append(_ kind: String, _ body: Data) { sent.withLock { $0.append((kind, body)) } }
}

import BloomProtocol
import Foundation
import Testing
@testable import BloomCore
@testable import BloomRunner

/// A new workspace's summary said its branch had no files on it: the schedule's first reading ran
/// before the clone existed and the machine slept before the second. The Mac drew "Nothing has
/// changed on this branch yet" and no Create pull request button from that number.
@Suite("Measuring the worktree when it has moved")
struct WorktreeMeasurementsTests {
    struct Fixture {
        let runtime: WorkspaceRuntime
        let reporter: MachineReporter
        let box: SentBox
        let host: RecordingHost
        let awake: AwakeController
        let measurements: WorktreeMeasurements
    }

    /// A branch with one file on it that its base does not have, and a machine holding nothing,
    /// which is what the thirty second schedule reads as a reason not to measure.
    func fixture(cloned: Bool = true) async throws -> Fixture {
        let store = try Store(path: NSTemporaryDirectory() + "bloom-measure-\(UUID().uuidString).sqlite")
        let path = try SetupTestSupport.directory("measure-worktree")
        try SetupTestSupport.bash(
            "git init -q -b main && git -c user.name=Bloom -c user.email=bloom@example.com commit -q --allow-empty -m Start",
            in: path
        )
        try SetupTestSupport.write("The agent wrote this\n", to: path + "/notes.txt")
        let workspace = try await RemoteMachineWorkspace.ensure(store: store, id: "01k5a7d3v1x0m8n2q4r6s9t0wz", name: "Measure",
                                                                 repository: "spatie/bloom", path: path, branch: "main", baseBranch: "main")
        let runtime = WorkspaceRuntime(store: store, workspaceID: workspace.id, makeRunner: { _, _, _, _, _, _ in NeverRunner() },
                                       installedAgents: { [.claudeCode] }, models: { _ in [] }, worktreeCloned: cloned)
        try await runtime.start()
        let host = RecordingHost()
        let box = SentBox()
        let delivery = ReportDelivery(sender: .init(summary: { box.append("summary", $0) }, usage: { box.append("usage", $0) }))
        let clock = TestClock(Date())
        let reporter = MachineReporter(runtime: runtime, store: store, delivery: delivery, host: host, version: "1.0.0", now: clock.reading)
        let awake = AwakeController(host: host, runtime: runtime, reporter: reporter, now: clock.reading)
        let measurements = WorktreeMeasurements(runtime: runtime, reporter: reporter)
        return Fixture(runtime: runtime, reporter: reporter, box: box, host: host, awake: awake, measurements: measurements)
    }

    @Test("setup finishing measures the branch at once, whether or not the machine holds itself awake")
    func setupFinishedMeasures() async throws {
        let fixture = try await fixture()
        #expect(await fixture.reporter.awake == false)
        await fixture.measurements.activity(.setupFinished(succeeded: true))
        #expect(await fixture.reporter.diff.files == 1)
        await fixture.runtime.shutdown()
    }

    @Test("a turn ending measures the branch at once")
    func turnEndedMeasures() async throws {
        let fixture = try await fixture()
        await fixture.measurements.activity(.turnFinished(chat: SessionID("chat"), turnID: "turn"))
        #expect(await fixture.reporter.diff.files == 1)
        await fixture.runtime.shutdown()
    }

    @Test("nothing else a runtime reports is a reason to run git")
    func otherActivityDoesNotMeasure() async throws {
        let fixture = try await fixture()
        await fixture.measurements.activity(.humanInput)
        await fixture.measurements.activity(.setupStep("prepare"))
        #expect(await fixture.reporter.diff.files == 0)
        await fixture.runtime.shutdown()
    }

    /// A checkout being written reads as every tracked file deleted, which is worse than no answer.
    @Test("nothing is measured before the clone has finished")
    func nothingBeforeTheClone() async throws {
        let fixture = try await fixture(cloned: false)
        await fixture.measurements.activity(.setupFinished(succeeded: true))
        #expect(await fixture.reporter.diff.files == 0)
        await fixture.runtime.worktreeChanged(cloned: true)
        await fixture.measurements.activity(.setupFinished(succeeded: true))
        #expect(await fixture.reporter.diff.files == 1)
        await fixture.runtime.shutdown()
    }

    @Test("the summary a machine sleeps on carries a diff measured before it let go")
    func measuredBeforeSleeping() async throws {
        let fixture = try await fixture()
        let measurements = fixture.measurements
        await fixture.awake.beforeSleeping { await measurements.measureNow() }
        await fixture.runtime.setupStepStarted("prepare")
        await fixture.awake.evaluate()
        #expect(fixture.host.log.withLock { $0 } == ["hold"])
        // Nothing measured it on the way: the event is not handed to the measurements here, so
        // what the last summary says is the release's own doing.
        await fixture.runtime.setupFinished(succeeded: true)
        await fixture.awake.evaluate()
        #expect(fixture.host.log.withLock { $0 } == ["hold", "release"])

        let body = try #require(fixture.box.sent.withLock { $0 }.last { $0.kind == "summary" }?.body)
        let summary = try WireJSON.decode(RemoteSummary.self, from: body)
        #expect(summary.awake == false)
        #expect(summary.diff.files == 1)
        await fixture.runtime.shutdown()
    }
}

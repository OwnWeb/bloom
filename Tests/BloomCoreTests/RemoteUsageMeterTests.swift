import Foundation
import Testing
@testable import BloomCore

@Suite("Cloud workspace usage meter")
struct RemoteUsageMeterTests {
    let start = Date(timeIntervalSince1970: 1_789_638_000)

    @Test("events beyond what one report may carry go in the next, oldest first, with the counters in each")
    func eventsAreSplitAcrossReports() {
        var meter = RemoteUsageMeter(bootID: "boot")
        for index in 0..<2_500 { meter.record(.released(at: start.addingTimeInterval(Double(index)))) }
        var reports: [UsageReport] = []
        repeat {
            reports.append(meter.report(at: start, includingDisk: false))
        } while meter.hasUnreportedEvents
        #expect(reports.map(\.events.count) == [1_000, 1_000])
        #expect(reports.first?.events.first?.at == start.addingTimeInterval(500), "The meter keeps the newest 2,000")
        #expect(reports.map(\.sequence) == [1, 2])
    }

    @Test("events recorded before a new boot's first reading are kept")
    func eventsSurviveABootReset() {
        var meter = RemoteUsageMeter(bootID: "old")
        meter.record(.setupStarted(at: start))
        meter.sample(MachineUsageReading(cpuSeconds: 1, memoryUsedBytes: 0, diskUsedBytes: nil, bootID: "new"), at: start, awake: true)
        let report = meter.report(at: start, includingDisk: false)
        #expect(report.machineBootID == "new")
        #expect(report.events.map(\.kind) == ["setup_started"])
    }
}

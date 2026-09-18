import Foundation
import Testing
@testable import BloomCore

/// A line in the layout `/proc/<pid>/stat` really has: pid, command in brackets, then state, ppid,
/// pgrp, session, tty, tpgid, flags, four fault counters, and then user and system time, which are
/// fields 14 and 15. The counting is the part worth getting right in the fixture as well as in the
/// parser, because a fixture that agrees with a wrong parser proves nothing.
private func stat(pid: Int32, parent: Int32, state: String, command: String = "bash",
                  user: UInt64 = 0, system: UInt64 = 0) -> String {
    let faults = Array(repeating: "0", count: 4).joined(separator: " ")
    return "\(pid) (\(command)) \(state) \(parent) \(pid) \(pid) 0 -1 4194304 \(faults) \(user) \(system) 0 0 20"
}

@Suite("What is alive under a setup step")
struct StepLivenessTests {
    @Test("a working tree counts the child and everything under it")
    func wholeTree() {
        let reading = StepLiveness.reading(child: 100, stats: [
            stat(pid: 1, parent: 0, state: "S", command: "bloom-runner"),
            stat(pid: 100, parent: 1, state: "S", user: 3, system: 1),
            stat(pid: 101, parent: 100, state: "R", command: "composer", user: 400, system: 20),
            stat(pid: 102, parent: 101, state: "R", command: "php", user: 50, system: 5),
            // Somebody else's process, which is not this step's business.
            stat(pid: 200, parent: 1, state: "R", command: "caddy", user: 999, system: 999),
        ])

        #expect(reading.running == 3)
        #expect(reading.defunct == 0)
        #expect(reading.ticks == 479)
        #expect(reading.isAlive)
    }

    /// The fault the reaper exists for, seen from the other side: the child is there and it is dead.
    @Test("a child that exited and was never collected is not alive")
    func zombieChild() {
        let reading = StepLiveness.reading(child: 100, stats: [
            stat(pid: 100, parent: 1, state: "Z", user: 1, system: 0),
        ])

        #expect(reading.running == 0)
        #expect(reading.defunct == 1)
        #expect(!reading.isAlive)
        #expect(StepLiveness.verdict(reading, since: nil) == .nothingAlive)
    }

    @Test("a child that is gone from proc altogether reads as nothing alive")
    func missingChild() {
        let reading = StepLiveness.reading(child: 100, stats: [stat(pid: 1, parent: 0, state: "S")])

        #expect(reading.running == 0)
        #expect(StepLiveness.verdict(reading, since: nil) == .nothingAlive)
    }

    /// The distinction the whole signal exists for. Neither of these is a reason to restart
    /// anything, and only one of them is a machine using its processor.
    @Test("processor time tells working apart from waiting, and neither is a stall")
    func workingAgainstWaiting() {
        let earlier = StepLiveness.Reading(running: 2, defunct: 0, ticks: 100)
        let busy = StepLiveness.Reading(running: 2, defunct: 0, ticks: 140)
        let idle = StepLiveness.Reading(running: 2, defunct: 0, ticks: 100)

        #expect(StepLiveness.verdict(busy, since: earlier) == .working)
        #expect(StepLiveness.verdict(idle, since: earlier) == .waiting)
        // A download that has printed nothing and used nothing is working as intended.
        #expect(StepLiveness.verdict(idle, since: earlier) != .nothingAlive)
    }

    /// With nothing to compare against, the ticks still count from the process's own start.
    @Test("the first look reads the total rather than a difference")
    func firstLook() {
        #expect(StepLiveness.verdict(.init(running: 1, defunct: 0, ticks: 7), since: nil) == .working)
        #expect(StepLiveness.verdict(.init(running: 1, defunct: 0, ticks: 0), since: nil) == .waiting)
    }

    /// `/proc` does not escape the command, so a process may call itself anything at all.
    @Test("a command containing brackets and spaces does not move the fields")
    func awkwardCommand() throws {
        let line = stat(pid: 100, parent: 1, state: "S", command: "sh (1) Z 1 1", user: 11, system: 2)
        let parsed = try #require(StepLiveness.parse(stat: line))

        #expect(parsed.pid == 100)
        #expect(parsed.parent == 1)
        #expect(!parsed.isDefunct)
        #expect(parsed.ticks == 13)
    }
}

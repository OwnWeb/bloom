import Foundation
import Synchronization
import Testing
@testable import BloomRunner

struct ReportDeliveryTests {
    /// What the injected sender saw, and how it answers: each queued failure is thrown once, in
    /// order, before sends start succeeding.
    final class Recorder: Sendable {
        private struct State {
            var summaries: [String] = []
            var usage: [String] = []
            var attempts = 0
            var failures: [any Error & Sendable] = []
            var delays: [Duration] = []
        }

        private let state = Mutex(State())

        var summaries: [String] { state.withLock { $0.summaries } }
        var usage: [String] { state.withLock { $0.usage } }
        var attempts: Int { state.withLock { $0.attempts } }
        var delays: [Duration] { state.withLock { $0.delays } }

        func fail(_ errors: (any Error & Sendable)...) {
            state.withLock { $0.failures.append(contentsOf: errors) }
        }

        func sent(_ body: Data, summary: Bool) throws {
            try state.withLock { state in
                state.attempts += 1
                if !state.failures.isEmpty { throw state.failures.removeFirst() }
                let text = String(decoding: body, as: UTF8.self)
                if summary { state.summaries.append(text) } else { state.usage.append(text) }
            }
        }

        func slept(_ duration: Duration) {
            state.withLock { $0.delays.append(duration) }
        }

        var sender: ReportDelivery.Sender {
            ReportDelivery.Sender(
                summary: { try self.sent($0, summary: true) },
                usage: { try self.sent($0, summary: false) }
            )
        }

        /// A sleep that records the backoff and returns at once, so a test of the schedule takes
        /// no time at all.
        var instantSleep: @Sendable (Duration) async throws -> Void {
            { self.slept($0) }
        }
    }

    private static let down = RunbloomError.unreachable("runbloom.app answered 503.")

    private static func data(_ text: String) -> Data { Data(text.utf8) }

    @Test func aSummaryAndUsageAreDelivered() async {
        let recorder = Recorder()
        let delivery = ReportDelivery(sender: recorder.sender, sleep: recorder.instantSleep)
        await delivery.submitSummary(Self.data("s1"))
        await delivery.submitUsage(Self.data("u1"))
        let delivered = await delivery.flush(timeout: .seconds(5))
        #expect(delivered)
        #expect(recorder.summaries == ["s1"])
        #expect(recorder.usage == ["u1"])
        #expect(recorder.delays.isEmpty)
    }

    @Test func aNewerSummaryReplacesAnUnsentOlderOne() async {
        let recorder = Recorder()
        let gate = Gate()
        let sender = ReportDelivery.Sender(
            summary: { body in
                await gate.passOnce()
                try recorder.sent(body, summary: true)
            },
            usage: { try recorder.sent($0, summary: false) }
        )
        let delivery = ReportDelivery(sender: sender, sleep: recorder.instantSleep)
        await delivery.submitSummary(Self.data("revision 1"))
        await gate.waitUntilHeld()
        await delivery.submitSummary(Self.data("revision 2"))
        await delivery.submitSummary(Self.data("revision 3"))
        await gate.release()

        let delivered = await delivery.flush(timeout: .seconds(5))
        #expect(delivered)
        #expect(recorder.summaries == ["revision 1", "revision 3"])
    }

    @Test func usageGoesInOrderAndWaitsBehindAFailure() async {
        let recorder = Recorder()
        recorder.fail(Self.down, Self.down)
        let delivery = ReportDelivery(sender: recorder.sender, sleep: recorder.instantSleep)
        await delivery.submitUsage(Self.data("1"))
        await delivery.submitUsage(Self.data("2"))
        await delivery.submitUsage(Self.data("3"))

        let delivered = await delivery.flush(timeout: .seconds(5))
        #expect(delivered)
        #expect(recorder.usage == ["1", "2", "3"])
        #expect(recorder.attempts == 5)
    }

    @Test func backoffDoublesFromOneSecondToAMinute() async {
        let recorder = Recorder()
        for _ in 0..<8 { recorder.fail(Self.down) }
        let delivery = ReportDelivery(sender: recorder.sender, sleep: recorder.instantSleep)
        await delivery.submitSummary(Self.data("s"))
        await waitUntil { recorder.summaries == ["s"] }

        let seconds: [Int64] = [1, 2, 4, 8, 16, 32, 60, 60]
        #expect(recorder.delays == seconds.map { .seconds($0) })
    }

    @Test func backoffStartsAgainAfterASuccess() async {
        let recorder = Recorder()
        recorder.fail(Self.down, Self.down)
        let delivery = ReportDelivery(sender: recorder.sender, sleep: recorder.instantSleep)
        await delivery.submitUsage(Self.data("1"))
        await waitUntil { recorder.usage == ["1"] }
        recorder.fail(Self.down)
        await delivery.submitUsage(Self.data("2"))
        await waitUntil { recorder.usage == ["1", "2"] }
        #expect(recorder.delays == [.seconds(1), .seconds(2), .seconds(1)])
    }

    @Test func aRefusalDropsTheReportAndTheRestCarryOn() async {
        let recorder = Recorder()
        recorder.fail(
            RunbloomError.refused(status: 422, code: "invalid", message: "Bad report.", limit: nil, retryAfter: nil),
            RunbloomError.unexpected(status: 400)
        )
        let delivery = ReportDelivery(sender: recorder.sender, sleep: recorder.instantSleep)
        await delivery.submitUsage(Self.data("rejected"))
        await delivery.submitUsage(Self.data("also rejected"))
        await delivery.submitUsage(Self.data("fine"))

        let delivered = await delivery.flush(timeout: .seconds(5))
        #expect(delivered)
        #expect(recorder.usage == ["fine"])
        #expect(recorder.attempts == 3)
        #expect(recorder.delays.isEmpty)
    }

    @Test func flushCutsABackoffShort() async {
        let recorder = Recorder()
        recorder.fail(Self.down)
        let delivery = ReportDelivery(sender: recorder.sender, initialDelay: .seconds(600), maximumDelay: .seconds(600))
        await delivery.submitSummary(Self.data("last words"))
        await waitUntil { recorder.attempts == 1 }

        let clock = ContinuousClock()
        let started = clock.now
        let delivered = await delivery.flush(timeout: .seconds(30))
        #expect(delivered)
        #expect(clock.now - started < .seconds(10))
        #expect(recorder.summaries == ["last words"])
    }

    @Test func flushGivesUpAtItsTimeout() async {
        let recorder = Recorder()
        for _ in 0..<1000 { recorder.fail(Self.down) }
        let delivery = ReportDelivery(sender: recorder.sender, initialDelay: .milliseconds(20), maximumDelay: .milliseconds(20))
        await delivery.submitUsage(Self.data("never"))

        let delivered = await delivery.flush(timeout: .milliseconds(200))
        #expect(!delivered)
        let pending = await delivery.hasPending
        #expect(pending)
        await delivery.shutdown()
    }

    @Test func nothingIsSentAfterShutdown() async {
        let recorder = Recorder()
        let delivery = ReportDelivery(sender: recorder.sender, sleep: recorder.instantSleep)
        await delivery.shutdown()
        await delivery.submitSummary(Self.data("late"))
        let delivered = await delivery.flush(timeout: .milliseconds(100))
        #expect(delivered)
        #expect(recorder.attempts == 0)
    }
}

/// Holds the first send until the test lets it go, so a test can submit while one is in flight.
private actor Gate {
    private var held = false
    private var released = false
    private var holders: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func passOnce() async {
        guard !held else { return }
        held = true
        for watcher in watchers { watcher.resume() }
        watchers = []
        if released { return }
        await withCheckedContinuation { holders.append($0) }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func release() {
        released = true
        for holder in holders { holder.resume() }
        holders = []
    }
}

/// Polls a condition the delivery reaches on its own worker, for at most five seconds.
private func waitUntil(_ condition: @Sendable () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

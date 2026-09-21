import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("Remote session preparation")
struct RemoteSessionPrepareTests {
    @Test("shutdown invalidates a runner factory suspended in launch", .timeLimit(.minutes(1)))
    func shutdownWinsSuspendedFactory() async {
        let gate = RemoteSessionLaunchGate()
        let fresh = RemoteSessionRaceRunner()
        let started = Mutex(false)
        let session = RemoteSession(runnerExitGrace: .milliseconds(20)) { _, _ in
            started.withLock { $0 = true }
            await gate.wait()
            return fresh
        }
        let preparing = Task {
            try await session.prepare(identity: "person", environment: [:])
        }
        await waitUntil("the runner factory suspended") { started.withLock { $0 } }

        await session.shutdown()
        await gate.release()
        await #expect(throws: RemoteFailure.self) { try await preparing.value }
        #expect(fresh.terminated.withLock { $0 })
        #expect(await session.runner == nil)
    }

    @Test("a newer prepare owns the session and retires the superseded result", .timeLimit(.minutes(1)))
    func newerPrepareWins() async throws {
        let gate = RemoteSessionLaunchGate()
        let first = RemoteSessionRaceRunner()
        let second = RemoteSessionRaceRunner()
        let launches = Mutex(0)
        let session = RemoteSession(runnerExitGrace: .milliseconds(20)) { _, _ in
            let number = launches.withLock { value in
                value += 1
                return value
            }
            if number == 1 {
                await gate.wait()
                return first
            }
            return second
        }
        let older = Task { try await session.prepare(identity: "old", environment: [:]) }
        await waitUntil("the first runner factory suspended") { launches.withLock { $0 } == 1 }
        try await session.prepare(identity: "new", environment: [:])

        await gate.release()
        await #expect(throws: RemoteFailure.self) { try await older.value }
        #expect(first.terminated.withLock { $0 })
        #expect(!second.terminated.withLock { $0 })
        await session.shutdown()
    }
}

private actor RemoteSessionLaunchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RemoteSessionRaceRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.claudeCode
    nonisolated let events = AsyncStream<AgentEvent> { _ in }
    nonisolated let terminated = Mutex(false)

    var isProcessAlive: Bool { !terminated.withLock { $0 } }
    func send(_ text: String, recording: Data?) async throws {}
    nonisolated func cancelNow() {}
    nonisolated func terminateNow() { terminated.withLock { $0 = true } }
    func answer(requestID: String, decision: PermissionDecision) async {}
}

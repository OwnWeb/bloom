import Testing
import Foundation
@testable import BloomCore

/// The result the runner says for a stopped turn the CLI never closed, and the guard in the
/// window behind it. See `UnreportedStop` and `OrphanedTurn` for the chat that queued every
/// message for the rest of the launch.
@Suite("A stopped turn with no result of its own", .tags(.agentProtocol))
struct UnreportedStopTests {
    @Test("only a stop that found a turn open, and that the CLI did not answer, owes a result")
    func owesOnlyWhenNothingElseClosedIt() {
        #expect(UnreportedStop.owesResult(stoppedMidTurn: true, reportedSince: false))
        // The CLI printed its own SIGTERM result, which is the ordinary case.
        #expect(!UnreportedStop.owesResult(stoppedMidTurn: true, reportedSince: true))
        // Stop landed after the turn had finished by itself, so a second footer would be a lie.
        #expect(!UnreportedStop.owesResult(stoppedMidTurn: false, reportedSince: false))
    }

    @Test("the line is the one the CLI prints for its own SIGTERM, and it closes the turn")
    func readsAsTheStopResult() throws {
        guard case .result(let result) = UnreportedStop.event(sessionID: "abc") else {
            Issue.record("the stand-in did not decode as a result")
            return
        }
        #expect(result.subtype == "error_during_execution")
        #expect(result.isError)
        #expect(result.sessionID == "abc")
        // A stray result closes nothing, so a stand-in read as one would put the bug back.
        #expect(!StrayResult.isStray(result))
        // And a person who pressed Stop is not told their click was a failure.
        #expect(result.outcome(wasCancelled: true) == nil)

        let payload = try #require(JSONValue.parse(result.raw))
        #expect(payload[UnreportedStop.marker]?.boolValue == true)
    }

    @Test("a session the CLI never named leaves the id out rather than writing an empty one")
    func noSessionID() {
        guard case .result(let result) = UnreportedStop.event(sessionID: nil) else {
            Issue.record("the stand-in did not decode as a result")
            return
        }
        #expect(result.sessionID == nil)
    }
}

@Suite("An open turn nothing is left to close")
struct OrphanedTurnTests {
    @Test("a stopped chat whose runner has nothing left to say closes its turn")
    func closesTheOwnersChat() {
        // The owner's chat, as it stood: a turn open, nothing running, the row filed as stopped,
        // and no process left to print anything.
        #expect(OrphanedTurn.shouldClose(
            hasActiveTurn: true, isRunning: false, isSettling: false,
            storedState: .cancelled, endingMayArrive: false
        ))
        #expect(OrphanedTurn.shouldClose(
            hasActiveTurn: true, isRunning: false, isSettling: false,
            storedState: .idle, endingMayArrive: false
        ))
    }

    @Test("a stopped process that may still print its result keeps the turn open")
    func waitsForALateResult() {
        // The second after Stop. The row already says `cancelled`, but the result the dying
        // process prints would otherwise land on the turn the next message starts.
        #expect(!OrphanedTurn.shouldClose(
            hasActiveTurn: true, isRunning: false, isSettling: false,
            storedState: .cancelled, endingMayArrive: true
        ))
    }

    @Test("a turn the runner still has in flight is not orphaned", arguments: [SessionState.running, .waiting])
    func midTurnIsNotOrphaned(state: SessionState) {
        #expect(!OrphanedTurn.shouldClose(
            hasActiveTurn: true, isRunning: false, isSettling: false,
            storedState: state, endingMayArrive: false
        ))
    }

    @Test("a running chat, a turn being wrapped up, and no open turn at all are left alone")
    func nothingToClose() {
        #expect(!OrphanedTurn.shouldClose(
            hasActiveTurn: true, isRunning: true, isSettling: false,
            storedState: .cancelled, endingMayArrive: false
        ))
        #expect(!OrphanedTurn.shouldClose(
            hasActiveTurn: true, isRunning: false, isSettling: true,
            storedState: .cancelled, endingMayArrive: false
        ))
        #expect(!OrphanedTurn.shouldClose(
            hasActiveTurn: false, isRunning: false, isSettling: false,
            storedState: .cancelled, endingMayArrive: false
        ))
        #expect(!OrphanedTurn.mightBe(hasActiveTurn: false, isRunning: false, isSettling: false))
    }
}

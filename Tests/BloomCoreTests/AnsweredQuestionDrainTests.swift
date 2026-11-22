import Foundation
import Testing
@testable import BloomCore

/// A message typed under a permission card waited for the end of the turn on every backend: the
/// drain the answer asked for ran inside the presentation batch, where `drain` refuses. These
/// hold the move the pump makes instead, once it has caught up. See `AnsweredQuestionDrain`.
@Suite struct AnsweredQuestionDrainTests {
    private static func answer(_ decision: String = "allow-once") -> AgentEvent {
        .permissionDecided(PermissionResolution(requestID: "question", decision: decision))
    }

    /// Whether one answer, alone in a batch of a running turn, moves the queue on that backend.
    private static func moves(after decision: String, on agent: AgentKind) -> Bool {
        let feed = AgentPresentationFeed()
        feed.yield(.initialized(AgentInit(sessionID: "session")))
        feed.yield(answer(decision))
        var answered = AnsweredQuestionDrain()
        answered.note(feed.read(after: 0), on: agent)
        return answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: false, isAwaitingQuestion: false)
    }

    /// OpenCode's one reject ends the turn, so the result moves the queue into the next one.
    @Test func aRefusalThatEndsTheTurnLeavesTheQueueToTheResult() {
        let deny = PermissionDecision.deny(message: "", endsTurn: false).storedName
        let denyAndStop = PermissionDecision.deny(message: "", endsTurn: true).storedName
        #expect(!Self.moves(after: deny, on: .openCode))
        #expect(!Self.moves(after: denyAndStop, on: .claudeCode))
        #expect(!Self.moves(after: denyAndStop, on: .codex))
    }

    /// Claude Code and Codex hand the model the refusal and carry on, so the turn takes the words.
    @Test func aRefusalTheTurnCarriesOnFromMovesTheQueue() {
        let deny = PermissionDecision.deny(message: "", endsTurn: false).storedName
        #expect(Self.moves(after: deny, on: .claudeCode))
        #expect(Self.moves(after: deny, on: .codex))
    }

    @Test func aQuestionNobodyAnsweredMovesNothing() {
        #expect(!Self.moves(after: PermissionAskOutcome.stopped, on: .openCode))
        #expect(!Self.moves(after: PermissionAskOutcome.resolved, on: .codex))
        #expect(Self.moves(after: PermissionAskOutcome.auto, on: .openCode))
    }

    @Test func anAnswerMidTurnMovesTheQueueOnceAndOnlyOnce() {
        let feed = AgentPresentationFeed()
        feed.yield(.initialized(AgentInit(sessionID: "session")))
        feed.yield(Self.answer())
        var answered = AnsweredQuestionDrain()
        answered.note(feed.read(after: 0), on: .openCode)

        let moves = answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: false, isAwaitingQuestion: false)
        let movesAgain = answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: false, isAwaitingQuestion: false)
        #expect(moves)
        #expect(!movesAgain)
    }

    @Test func anAnswerIsKeptWhileThePumpCatchesUpOnTheBatchesAfterIt() {
        let feed = AgentPresentationFeed()
        feed.yield(.initialized(AgentInit(sessionID: "session")))
        feed.yield(Self.answer())
        let withAnswer = feed.read(after: 0)
        feed.yield(.streamDelta(.text("the tool ran")))
        var answered = AnsweredQuestionDrain()
        answered.note(withAnswer, on: .openCode)
        answered.note(feed.read(after: withAnswer.revision), on: .openCode)

        let moves = answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: false, isAwaitingQuestion: false)
        #expect(moves)
    }

    @Test func aBatchWithNoAnswerOwesNothing() {
        let feed = AgentPresentationFeed()
        feed.yield(.initialized(AgentInit(sessionID: "session")))
        feed.yield(.streamDelta(.text("working")))
        var answered = AnsweredQuestionDrain()
        answered.note(feed.read(after: 0), on: .openCode)

        let moves = answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: false, isAwaitingQuestion: false)
        #expect(!moves)
    }

    /// OpenCode's reject ends the turn, so the answer and the result can arrive in one batch.
    @Test func anAnswerWhoseTurnEndedLeavesTheQueueToTheResult() {
        let feed = AgentPresentationFeed()
        feed.yield(.initialized(AgentInit(sessionID: "session")))
        feed.yield(Self.answer())
        feed.yield(.result(AgentResult(summary: "Refused")))
        var answered = AnsweredQuestionDrain()
        answered.note(feed.read(after: 0), on: .openCode)

        let moves = answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: true, isAwaitingQuestion: false)
        let movesOnceTheNextTurnRuns = answered.take(isTurnRunning: true, hasPendingResult: false, isAwaitingQuestion: false)
        #expect(!moves)
        #expect(!movesOnceTheNextTurnRuns)
    }

    @Test func anAnswerAfterTheTurnStoppedMovesNothing() {
        let feed = AgentPresentationFeed()
        feed.yield(.initialized(AgentInit(sessionID: "session")))
        feed.yield(.error(AgentError(message: "The agent exited")))
        feed.yield(Self.answer())
        var answered = AnsweredQuestionDrain()
        answered.note(feed.read(after: 0), on: .openCode)

        let moves = answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: false, isAwaitingQuestion: false)
        #expect(!feed.isTurnRunning)
        #expect(!moves)
    }

    @Test func anotherOpenQuestionKeepsHoldingTheQueue() {
        let feed = AgentPresentationFeed()
        feed.yield(.initialized(AgentInit(sessionID: "session")))
        feed.yield(Self.answer())
        var answered = AnsweredQuestionDrain()
        answered.note(feed.read(after: 0), on: .openCode)

        let moves = answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: false, isAwaitingQuestion: true)
        #expect(!moves)
    }

    /// The known limit: an overflow rebuilds the batch without its events.
    @Test func anAnswerLostToAnOverflowOwesNothing() {
        let feed = AgentPresentationFeed(maxItems: 2)
        feed.yield(.initialized(AgentInit(sessionID: "session")))
        feed.yield(Self.answer())
        for index in 0..<10 { feed.yield(.status(String(index))) }
        let batch = feed.read(after: 0)
        var answered = AnsweredQuestionDrain()
        answered.note(batch, on: .openCode)

        let moves = answered.take(isTurnRunning: feed.isTurnRunning, hasPendingResult: false, isAwaitingQuestion: false)
        #expect(batch.recovery != nil)
        #expect(!moves)
    }
}

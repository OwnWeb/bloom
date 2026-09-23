import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

/// Which Cloud question rows read as answered. See `CloudQuestionSettlement`.
@Suite("A Cloud question is answered on evidence, not on being absent")
struct CloudQuestionSettlementTests {
    private let ask = CloudQuestionSettlement.OpenAsk(requestID: "req-1", toolUseID: "toolu_01", seq: 3)

    private func row(_ seq: Int, _ kind: MessageKind, refID: String? = nil) -> MessageRecord {
        MessageRecord(
            cursor: Int64(seq), chatID: "chat", seq: seq, kind: kind.rawValue, payload: .null,
            createdAt: Date(timeIntervalSince1970: 0), refID: refID
        )
    }

    private var askedSoFar: [MessageRecord] {
        [row(1, .user), row(2, .toolUse, refID: "toolu_01"), row(3, .permissionAsk, refID: "toolu_01")]
    }

    /// The bug: the row reached the Mac before the question did, read as a question nobody was
    /// waiting on, and was drawn "Answered." over an agent still blocked on it.
    @Test("a row that arrives ahead of its question stays open, and settles when the question goes")
    func rowAheadOfQuestion() {
        var settlement = CloudQuestionSettlement()
        let early = settlement.answered([ask], waiting: [], messages: askedSoFar)
        #expect(early.isEmpty)
        let asked = settlement.answered([ask], waiting: ["req-1"], messages: askedSoFar)
        #expect(asked.isEmpty)
        let gone = settlement.answered([ask], waiting: [], messages: askedSoFar)
        #expect(gone == ["req-1"])
    }

    @Test("a question the transcript went past is answered, though nobody saw it waiting")
    func historyIsSettledByWhatFollows() {
        var byItsResult = CloudQuestionSettlement()
        let answeredByResult = byItsResult.answered(
            [ask], waiting: [], messages: askedSoFar + [row(4, .toolResult, refID: "toolu_01")]
        )
        #expect(answeredByResult == ["req-1"])

        var byTheTurnEnding = CloudQuestionSettlement()
        let answeredByTurn = byTheTurnEnding.answered([ask], waiting: [], messages: askedSoFar + [row(4, .result)])
        #expect(answeredByTurn == ["req-1"])
    }

    @Test("another call's result, or a row before the question, proves nothing about it")
    func unrelatedRowsProveNothing() {
        var settlement = CloudQuestionSettlement()
        let before = [row(0, .result), row(1, .toolResult, refID: "toolu_01")]
        let after = [row(4, .toolResult, refID: "toolu_02"), row(5, .assistantText)]
        let answered = settlement.answered(
            [ask], waiting: [], messages: before + askedSoFar.dropFirst() + after
        )
        #expect(answered.isEmpty)
    }

    @Test("a question the machine lists as waiting is open, whatever the rows say")
    func waitingIsOpen() {
        var settlement = CloudQuestionSettlement()
        let answered = settlement.answered([ask], waiting: ["req-1"], messages: askedSoFar + [row(4, .result)])
        #expect(answered.isEmpty)
    }

    @Test("several open questions are each judged on their own")
    func severalQuestions() {
        let older = CloudQuestionSettlement.OpenAsk(requestID: "req-0", toolUseID: "toolu_00", seq: 1)
        let messages = [
            row(1, .permissionAsk, refID: "toolu_00"), row(2, .toolResult, refID: "toolu_00"),
            row(3, .permissionAsk, refID: "toolu_01"),
        ]
        var settlement = CloudQuestionSettlement()
        let answered = settlement.answered([older, ask], waiting: [], messages: messages)
        #expect(answered == ["req-0"])
    }
}

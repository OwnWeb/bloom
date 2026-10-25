import Testing
@testable import BloomCore

@Suite("An answer too long to build twice")
struct TranscriptLongAnswerTests {
    @Test("a long answer is estimated from its size instead of being measured off screen")
    func longAnswerIsEstimated() {
        let estimate = TranscriptLongAnswer.estimate(kind: .assistantText, payloadBytes: 140_674)
        #expect(estimate.map { abs($0 - 30_948) < 1 } == true)
    }

    @Test("a short answer, or a long row of another kind, is measured as usual")
    func othersAreMeasured() {
        #expect(TranscriptLongAnswer.estimate(kind: .assistantText, payloadBytes: 19_999) == nil)
        #expect(TranscriptLongAnswer.estimate(kind: .toolResult, payloadBytes: 140_674) == nil)
        #expect(TranscriptLongAnswer.estimate(kind: .user, payloadBytes: 140_674) == nil)
    }
}

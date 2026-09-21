import Testing
@testable import BloomCore

@Suite("Completed turn folding")
struct TranscriptTurnFoldTests {
    private func fact(
        _ seq: Int,
        _ kind: MessageKind,
        drawsNothing: Bool = false,
        parent: String? = nil,
        durationMS: Int? = nil
    ) -> TranscriptTurnFold.Fact {
        TranscriptTurnFold.Fact(
            seq: seq,
            kind: kind,
            drawsNothing: drawsNothing,
            parentToolUseID: parent,
            durationMS: durationMS
        )
    }

    @Test("a completed turn hides its streamed process and keeps its final response")
    func completedTurn() throws {
        let facts = [
            fact(0, .user),
            fact(1, .assistantText),
            fact(2, .toolUse),
            fact(3, .thinking, drawsNothing: true),
            fact(4, .assistantText),
            fact(5, .result, durationMS: 65_000),
        ]

        let folds = TranscriptTurnFold.folds(in: facts)
        let turn = try #require(folds.all.first)

        #expect(turn.firstSeq == 1)
        #expect(turn.hidden == [1, 2])
        #expect(turn.hiddenSeqs == [1, 2])
        #expect(turn.span == 1..<6)
        #expect(TranscriptTurnFold.label(milliseconds: turn.durationMS ?? 0) == "Worked for 1m 5s")
    }

    @Test("the process stays visible until a result identifies the final response")
    func liveTurn() throws {
        let facts = [fact(0, .user), fact(1, .assistantText), fact(2, .toolUse)]
        let folds = TranscriptTurnFold.folds(in: facts)
        let turn = try #require(folds.all.first)

        #expect(!turn.isComplete)
        #expect(turn.hidden.isEmpty)
        #expect(turn.firstSeq == 1)
    }

    @Test("a turn with no process before its response draws no disclosure")
    func directResponse() throws {
        let facts = [fact(0, .user), fact(1, .assistantText), fact(2, .result, durationMS: 800)]
        let turn = try #require(TranscriptTurnFold.folds(in: facts).all.first)

        #expect(turn.isComplete)
        #expect(!turn.hasHiddenRows)
    }

    @Test("revealing a hidden row opens its completed turn")
    func revealedRow() throws {
        let facts = [
            fact(0, .user),
            fact(1, .assistantText),
            fact(2, .toolUse),
            fact(3, .assistantText),
            fact(4, .result, durationMS: 2_000),
        ]
        let folds = TranscriptTurnFold.folds(in: facts)
        let turn = try #require(folds.all.first)

        #expect(folds.hiddenIndices(unfolded: [], revealed: []) == [1, 2])
        #expect(folds.hiddenIndices(unfolded: [], revealed: [2]).isEmpty)
        #expect(folds.isOpen(turn, unfolded: [1], revealed: []))
    }

    @Test("a rescan keeps completed history and rebuilds only the live tail")
    func extending() {
        var facts = [
            fact(0, .user),
            fact(1, .toolUse),
            fact(2, .assistantText),
            fact(3, .result, durationMS: 1_000),
            fact(4, .user),
            fact(5, .assistantText),
        ]
        var folds = TranscriptTurnFold.folds(in: facts)
        facts.append(fact(6, .toolUse))
        folds = TranscriptTurnFold.folds(in: facts, extending: folds)
        facts.append(fact(7, .assistantText))
        facts.append(fact(8, .result, durationMS: 2_000))
        folds = TranscriptTurnFold.folds(in: facts, extending: folds)

        #expect(folds == TranscriptTurnFold.folds(in: facts))
        #expect(folds.all.map(\.firstSeq) == [1, 5])
    }
}

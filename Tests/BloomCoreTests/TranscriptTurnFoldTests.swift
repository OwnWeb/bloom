import Foundation
import Testing
@testable import BloomCore

@Suite("Completed turn folding")
struct TranscriptTurnFoldTests {
    private func fact(
        _ seq: Int,
        _ kind: MessageKind,
        drawsNothing: Bool = false,
        parent: String? = nil,
        durationMS: Int? = nil,
        createdAt: TimeInterval? = nil
    ) -> TranscriptTurnFold.Fact {
        TranscriptTurnFold.Fact(
            seq: seq,
            kind: kind,
            drawsNothing: drawsNothing,
            parentToolUseID: parent,
            durationMS: durationMS,
            createdAt: createdAt.map(Date.init(timeIntervalSince1970:))
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
        #expect(turn.hidden == [1, 2, 3])
        #expect(turn.hiddenSeqs == [1, 2, 3])
        #expect(turn.hasHiddenRows)
        #expect(turn.span == 1..<6)
        #expect(turn.displayIndex == 4)
        #expect(TranscriptTurnFold.label(milliseconds: turn.durationMS ?? 0) == "Worked for 1m 5s")
    }

    @Test("a zero-second legacy duration reads naturally")
    func zeroDuration() {
        #expect(TranscriptTurnFold.label(milliseconds: 0) == "Worked for a while")
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

    @Test("invisible rows inside the process cannot leave an inner action fold behind")
    func hidesInvisibleFoldHeaders() throws {
        let facts = [
            fact(0, .user),
            fact(1, .assistantText),
            fact(2, .system, drawsNothing: true),
            fact(3, .toolUse),
            fact(4, .assistantText),
            fact(5, .result, durationMS: 14_000),
        ]
        let folds = TranscriptTurnFold.folds(in: facts)
        let turn = try #require(folds.all.first)

        #expect(turn.hidden == [1, 2, 3])
        #expect(folds.hiddenIndices(unfolded: [], revealed: []) == [1, 2, 3])
    }

    @Test("a missing backend duration is measured from the turn timestamps")
    func measuredDuration() throws {
        let facts = [
            fact(0, .user, createdAt: 100),
            fact(1, .toolUse, createdAt: 102),
            fact(2, .assistantText, createdAt: 113),
            fact(3, .result, durationMS: 0, createdAt: 114),
        ]
        let turn = try #require(TranscriptTurnFold.folds(in: facts).all.first)

        #expect(turn.durationMS == 14_000)
        #expect(TranscriptTurnFold.label(milliseconds: turn.durationMS ?? 0) == "Worked for 14s")
    }

    @Test("a steering message closes the work before its bubble and starts a new timer")
    func steeringMessage() throws {
        let facts = [
            fact(0, .user, createdAt: 100),
            fact(1, .assistantText, createdAt: 102),
            fact(2, .toolUse, createdAt: 104),
            fact(3, .user, createdAt: 110),
            fact(4, .toolUse, createdAt: 111),
            fact(5, .assistantText, createdAt: 113),
            fact(6, .result, durationMS: 14_000, createdAt: 114),
        ]
        let turns = TranscriptTurnFold.folds(in: facts).all

        #expect(turns.count == 2)
        #expect(turns[0].hidden == [1, 2])
        #expect(turns[0].displayIndex == 3)
        #expect(turns[0].durationMS == 10_000)
        #expect(turns[1].hidden == [4])
        #expect(turns[1].displayIndex == 5)
        #expect(turns[1].durationMS == 4_000)
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

import Foundation

/// A completed turn's streamed working, folded behind one line before its final response.
///
/// `TranscriptFold` keeps a live turn readable by folding consecutive runs of actions while the
/// agent's commentary stays in place. Once the result row arrives, that commentary is history as
/// well: the last top-level assistant message is the response, and everything between the user's
/// message and that response can leave the scrolling path until somebody asks to see it.
///
/// A live turn is still returned with nothing hidden. Its entry can therefore take its stable
/// place at the start of the work before completion removes any rows from the table.
public enum TranscriptTurnFold {
    public struct Fact: Equatable, Sendable {
        public var seq: Int
        public var kind: MessageKind
        public var drawsNothing: Bool
        public var parentToolUseID: String?
        public var opensTurn: Bool
        public var durationMS: Int?

        public init(
            seq: Int,
            kind: MessageKind,
            drawsNothing: Bool = false,
            parentToolUseID: String? = nil,
            opensTurn: Bool = false,
            durationMS: Int? = nil
        ) {
            self.seq = seq
            self.kind = kind
            self.drawsNothing = drawsNothing
            self.parentToolUseID = parentToolUseID
            self.opensTurn = opensTurn
            self.durationMS = durationMS
        }
    }

    public struct Turn: Equatable, Sendable {
        /// Every stored row from the first work row through the result, or through the live tail.
        public var span: Range<Int>
        /// The rows before the final response. Empty until the turn has a result and a response.
        public var hidden: Set<Int>
        /// The sequence numbers corresponding to `hidden`, for a search or restored position.
        public var hiddenSeqs: Set<Int>
        public var firstSeq: Int
        public var isComplete: Bool
        public var durationMS: Int?

        public init(
            span: Range<Int>,
            hidden: Set<Int>,
            hiddenSeqs: Set<Int>,
            firstSeq: Int,
            isComplete: Bool,
            durationMS: Int? = nil
        ) {
            self.span = span
            self.hidden = hidden
            self.hiddenSeqs = hiddenSeqs
            self.firstSeq = firstSeq
            self.isComplete = isComplete
            self.durationMS = durationMS
        }

        public var hasHiddenRows: Bool { !hidden.isEmpty }
    }

    public struct Folds: Equatable, Sendable {
        public var all: [Turn]
        public var scannedRows: Int
        /// Just past the last result row. The unfinished tail is rescanned as it grows.
        public var resumeIndex: Int

        public static let none = Folds(all: [], scannedRows: 0, resumeIndex: 0)

        public init(all: [Turn], scannedRows: Int, resumeIndex: Int) {
            self.all = all
            self.scannedRows = scannedRows
            self.resumeIndex = resumeIndex
        }

        public func turn(startingAt index: Int) -> Turn? {
            guard let turn = turn(containing: index), turn.span.lowerBound == index else { return nil }
            return turn
        }

        public func turn(containing index: Int) -> Turn? {
            var low = 0
            var high = all.count
            while low < high {
                let middle = low + (high - low) / 2
                let turn = all[middle]
                if turn.span.upperBound <= index {
                    low = middle + 1
                } else if index < turn.span.lowerBound {
                    high = middle
                } else {
                    return turn
                }
            }
            return nil
        }

        public func hiddenIndices(
            unfolded: Set<Int>,
            revealed: Set<Int>,
            drawn: Range<Int> = 0..<Int.max
        ) -> Set<Int> {
            var hidden: Set<Int> = []
            for turn in all where turn.span.lowerBound >= drawn.lowerBound
                && turn.span.upperBound <= drawn.upperBound
                && !isOpen(turn, unfolded: unfolded, revealed: revealed) {
                hidden.formUnion(turn.hidden)
            }
            return hidden
        }

        public func isOpen(_ turn: Turn, unfolded: Set<Int>, revealed: Set<Int>) -> Bool {
            unfolded.contains(turn.firstSeq) || !turn.hiddenSeqs.isDisjoint(with: revealed)
        }
    }

    public static func folds<Facts: RandomAccessCollection>(
        in facts: Facts,
        extending previous: Folds = .none
    ) -> Folds where Facts.Element == Fact, Facts.Index == Int {
        let count = facts.count
        var start = previous.resumeIndex
        var found: [Turn]
        if count < previous.scannedRows || start > count {
            start = 0
            found = []
        } else {
            found = previous.all.filter { $0.span.upperBound <= start }
        }

        var turnStart: Int?
        var finalResponse: Int?
        var resume = start

        func appendTurn(endingAt end: Int, isComplete: Bool, durationMS: Int?) {
            guard let turnStart, turnStart < end else { return }
            let first = facts[facts.index(facts.startIndex, offsetBy: turnStart)]
            var hidden: Set<Int> = []
            var hiddenSeqs: Set<Int> = []

            if let finalResponse, isComplete, turnStart < finalResponse {
                for index in turnStart..<finalResponse {
                    let fact = facts[facts.index(facts.startIndex, offsetBy: index)]
                    guard !fact.drawsNothing else { continue }
                    hidden.insert(index)
                    hiddenSeqs.insert(fact.seq)
                }
            }

            found.append(Turn(
                span: turnStart..<end,
                hidden: hidden,
                hiddenSeqs: hiddenSeqs,
                firstSeq: first.seq,
                isComplete: isComplete,
                durationMS: durationMS
            ))
        }

        for offset in start..<count {
            let fact = facts[facts.index(facts.startIndex, offsetBy: offset)]
            guard fact.parentToolUseID == nil else { continue }

            if fact.kind == .user || fact.kind == .crew || fact.opensTurn {
                turnStart = offset + 1
                finalResponse = nil
                continue
            }

            if fact.kind == .assistantText, turnStart != nil, !fact.drawsNothing {
                finalResponse = offset
                continue
            }

            if fact.kind == .result {
                appendTurn(endingAt: offset + 1, isComplete: true, durationMS: fact.durationMS)
                turnStart = nil
                finalResponse = nil
                resume = offset + 1
            }
        }

        if turnStart != nil {
            appendTurn(endingAt: count, isComplete: false, durationMS: nil)
        }

        return Folds(all: found, scannedRows: count, resumeIndex: min(resume, count))
    }

    public static func label(milliseconds: Int) -> String {
        "Worked for \(TurnDuration.wholeSeconds(milliseconds))"
    }
}

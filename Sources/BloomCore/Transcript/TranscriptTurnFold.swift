import Foundation

/// A completed work segment, folded behind one line before the next message that stays visible.
///
/// `TranscriptFold` keeps a live turn readable by folding consecutive runs of actions while the
/// agent's commentary stays in place. Once the result row or another user message arrives, the
/// preceding work is history. A result keeps the last top-level assistant message as its response,
/// while a steering message closes all the work before its own bubble.
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
        public var createdAt: Date?

        public init(
            seq: Int,
            kind: MessageKind,
            drawsNothing: Bool = false,
            parentToolUseID: String? = nil,
            opensTurn: Bool = false,
            durationMS: Int? = nil,
            createdAt: Date? = nil
        ) {
            self.seq = seq
            self.kind = kind
            self.drawsNothing = drawsNothing
            self.parentToolUseID = parentToolUseID
            self.opensTurn = opensTurn
            self.durationMS = durationMS
            self.createdAt = createdAt
        }
    }

    public struct Turn: Equatable, Sendable {
        /// Every stored row from the first work row through the result, or through the live tail.
        public var span: Range<Int>
        /// The working rows replaced by the disclosure once this segment is complete.
        public var hidden: Set<Int>
        /// The sequence numbers corresponding to `hidden`, for a search or restored position.
        public var hiddenSeqs: Set<Int>
        public var firstSeq: Int
        /// The row immediately after the folded work, where its disclosure is drawn.
        public var displayIndex: Int
        public var isComplete: Bool
        /// Whether at least one hidden stored row draws content of its own.
        public var hasHiddenRows: Bool
        public var durationMS: Int?

        public init(
            span: Range<Int>,
            hidden: Set<Int>,
            hiddenSeqs: Set<Int>,
            firstSeq: Int,
            displayIndex: Int,
            isComplete: Bool,
            hasHiddenRows: Bool,
            durationMS: Int? = nil
        ) {
            self.span = span
            self.hidden = hidden
            self.hiddenSeqs = hiddenSeqs
            self.firstSeq = firstSeq
            self.displayIndex = displayIndex
            self.isComplete = isComplete
            self.hasHiddenRows = hasHiddenRows
            self.durationMS = durationMS
        }
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
            var low = 0
            var high = all.count
            while low < high {
                let middle = low + (high - low) / 2
                let displayIndex = all[middle].displayIndex
                if displayIndex < index {
                    low = middle + 1
                } else if index < displayIndex {
                    high = middle
                } else {
                    return all[middle]
                }
            }
            return nil
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
        var turnStartedAt: Date?
        var acceptsResultDuration = true
        var finalResponse: Int?
        var resume = start

        func elapsed(until end: Date?) -> Int? {
            turnStartedAt.flatMap { started in
                end.map { max(0, Int($0.timeIntervalSince(started) * 1_000)) }
            }
        }

        func appendTurn(
            endingAt end: Int,
            displayAt displayIndex: Int? = nil,
            isComplete: Bool,
            durationMS: Int?,
            hidesEntireSpan: Bool = false
        ) {
            guard let turnStart, turnStart < end else { return }
            let first = facts[facts.index(facts.startIndex, offsetBy: turnStart)]
            var hidden: Set<Int> = []
            var hiddenSeqs: Set<Int> = []
            var hasHiddenRows = false

            let hiddenEnd = hidesEntireSpan ? end : finalResponse
            if let hiddenEnd, isComplete, turnStart < hiddenEnd {
                for index in turnStart..<hiddenEnd {
                    let fact = facts[facts.index(facts.startIndex, offsetBy: index)]
                    hidden.insert(index)
                    hiddenSeqs.insert(fact.seq)
                    hasHiddenRows = hasHiddenRows || !fact.drawsNothing
                }
            }

            found.append(Turn(
                span: turnStart..<end,
                hidden: hidden,
                hiddenSeqs: hiddenSeqs,
                firstSeq: first.seq,
                displayIndex: displayIndex ?? finalResponse ?? turnStart,
                isComplete: isComplete,
                hasHiddenRows: hasHiddenRows,
                durationMS: durationMS
            ))
        }

        for offset in start..<count {
            let fact = facts[facts.index(facts.startIndex, offsetBy: offset)]
            guard fact.parentToolUseID == nil else { continue }

            if fact.kind == .user || fact.kind == .crew || fact.opensTurn {
                if turnStart != nil {
                    appendTurn(
                        endingAt: offset,
                        displayAt: offset,
                        isComplete: true,
                        durationMS: elapsed(until: fact.createdAt),
                        hidesEntireSpan: true
                    )
                    acceptsResultDuration = false
                } else {
                    acceptsResultDuration = true
                }
                turnStartedAt = fact.createdAt
                turnStart = offset + 1
                finalResponse = nil
                continue
            }

            if fact.kind == .assistantText, turnStart != nil, !fact.drawsNothing {
                finalResponse = offset
                continue
            }

            if fact.kind == .result {
                let reported = acceptsResultDuration
                    ? fact.durationMS.flatMap { $0 > 0 ? $0 : nil }
                    : nil
                let durationMS = reported ?? elapsed(until: fact.createdAt)
                appendTurn(endingAt: offset + 1, isComplete: true, durationMS: durationMS)
                turnStart = nil
                turnStartedAt = nil
                acceptsResultDuration = true
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
        let duration = TurnDuration.wholeSeconds(milliseconds)
        return duration == "0s" ? "Worked for a while" : "Worked for \(duration)"
    }
}

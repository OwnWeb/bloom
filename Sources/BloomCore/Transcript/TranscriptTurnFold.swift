import Foundation

/// The boundaries and duration of each agent turn.
///
/// `TranscriptFold` owns the activity groups within a turn. This scan only finds where a completed
/// turn ends, so its duration can be shown after the agent's text and its action groups can be
/// opened together. It keeps completed turns when new rows arrive and rescans only the live tail.
public enum TranscriptTurnFold {
    public struct Fact: Equatable, Sendable {
        public var seq: Int
        public var kind: MessageKind
        public var parentToolUseID: String?
        public var opensTurn: Bool
        public var durationMS: Int?
        public var createdAt: Date?

        public init(
            seq: Int,
            kind: MessageKind,
            parentToolUseID: String? = nil,
            opensTurn: Bool = false,
            durationMS: Int? = nil,
            createdAt: Date? = nil
        ) {
            self.seq = seq
            self.kind = kind
            self.parentToolUseID = parentToolUseID
            self.opensTurn = opensTurn
            self.durationMS = durationMS
            self.createdAt = createdAt
        }
    }

    public struct Turn: Equatable, Sendable {
        /// Stored rows from the first work row through the result, or up to the next user message.
        public var span: Range<Int>
        public var firstSeq: Int
        public var isComplete: Bool
        public var durationMS: Int?

        public init(span: Range<Int>, firstSeq: Int, isComplete: Bool, durationMS: Int? = nil) {
            self.span = span
            self.firstSeq = firstSeq
            self.isComplete = isComplete
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

        /// A turn interrupted by the user ends immediately before that user's row.
        public func turn(endingAt index: Int) -> Turn? {
            guard index > 0, let turn = turn(containing: index - 1),
                  turn.span.upperBound == index else { return nil }
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
    }

    /// The action groups available to a completed turn's disclosure in the drawn window.
    public struct Disclosures: Sendable {
        public var hiddenByWork: [Int: Set<Int>]
        public var turnByWork: [Int: Int]
        public var expandableTurns: Set<Int>
    }

    public static func disclosures(
        work: TranscriptFold.Folds,
        turns: Folds,
        revealed: Set<Int>,
        drawn: Range<Int>
    ) -> Disclosures {
        var hiddenByWork: [Int: Set<Int>] = [:]
        var turnByWork: [Int: Int] = [:]
        var expandableTurns: Set<Int> = []
        for group in work.all where drawn.contains(group.span.lowerBound) {
            let hidden = TranscriptFold.hiddenIndices(group, revealed: revealed, drawn: drawn)
            guard !hidden.isEmpty else { continue }
            hiddenByWork[group.firstSeq] = hidden
            if let turn = turns.turn(containing: group.span.lowerBound), turn.isComplete {
                turnByWork[group.firstSeq] = turn.firstSeq
                expandableTurns.insert(turn.firstSeq)
            }
        }
        return Disclosures(
            hiddenByWork: hiddenByWork,
            turnByWork: turnByWork,
            expandableTurns: expandableTurns
        )
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
        var resume = start

        func elapsed(until end: Date?) -> Int? {
            turnStartedAt.flatMap { started in
                end.map { max(0, Int($0.timeIntervalSince(started) * 1_000)) }
            }
        }

        func appendTurn(endingAt end: Int, isComplete: Bool, durationMS: Int?) {
            guard let turnStart, turnStart < end else { return }
            let first = facts[facts.index(facts.startIndex, offsetBy: turnStart)]
            found.append(Turn(
                span: turnStart..<end,
                firstSeq: first.seq,
                isComplete: isComplete,
                durationMS: durationMS
            ))
        }

        for offset in start..<count {
            let fact = facts[facts.index(facts.startIndex, offsetBy: offset)]
            guard fact.parentToolUseID == nil else { continue }

            if fact.kind == .user || fact.kind == .crew || fact.opensTurn {
                if turnStart != nil {
                    // A background wake starts new work without ending the previous turn.
                    if !fact.opensTurn {
                        appendTurn(endingAt: offset, isComplete: true,
                                   durationMS: elapsed(until: fact.createdAt))
                    }
                    acceptsResultDuration = false
                } else {
                    acceptsResultDuration = true
                }
                turnStartedAt = fact.createdAt
                turnStart = offset + 1
                continue
            }

            if fact.kind == .result {
                let reported = acceptsResultDuration
                    ? fact.durationMS.flatMap { $0 > 0 ? $0 : nil }
                    : nil
                appendTurn(endingAt: offset + 1, isComplete: true,
                           durationMS: reported ?? elapsed(until: fact.createdAt))
                turnStart = nil
                turnStartedAt = nil
                acceptsResultDuration = true
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

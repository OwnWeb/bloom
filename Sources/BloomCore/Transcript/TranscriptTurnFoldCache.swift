/// Turn boundaries owned by a conversation, so reopening its pane does not rescan every row.
/// The completed prefix is retained while new work arrives at the live end.
public struct TranscriptTurnFoldCache: Sendable {
    private var held = TranscriptTurnFold.Folds.none
    private var dirty = true

    public init() {}

    public mutating func reset() {
        held = .none
        dirty = true
    }

    public mutating func invalidate(row index: Int) {
        if index < held.resumeIndex { held = .none }
        dirty = true
    }

    public mutating func resolve<Facts: RandomAccessCollection>(
        _ facts: Facts
    ) -> TranscriptTurnFold.Folds where Facts.Element == TranscriptTurnFold.Fact, Facts.Index == Int {
        guard dirty || held.scannedRows != facts.count else { return held }
        held = TranscriptTurnFold.folds(in: facts, extending: held)
        dirty = false
        return held
    }
}

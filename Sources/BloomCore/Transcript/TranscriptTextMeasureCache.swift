import Foundation

/// The answers one run of transcript prose has already given, one per question.
///
/// **One remembered answer was not enough, and the reason is how SwiftUI asks.** A run inside an
/// `HStack`, which is every item of a markdown list with its marker beside it, is asked the same
/// question at several widths in one layout pass: zero, infinity, a hair, and then the width it is
/// placed at. The view used to keep only the last answer, so each of those questions threw the
/// previous one away and TextKit typeset the whole run again. A nested list is another stack at
/// every level, asking its children the same questions.
///
/// Measured with temporary counters over a contributor's conversations, during twelve workspace
/// visits and some scrolling: about 320,000 size questions, 262,000 of them answered by typesetting
/// again. The misses moved between 0, infinity, 1 and the pane's width, over and over, and the
/// heaviest content was nested lists.
///
/// So every question keeps its own answer until the text changes. The number kept is bounded,
/// because a divider drag asks a new width on every frame and the old ones are never asked again.
/// The answer asked for least recently is the one dropped, so the questions every pass repeats
/// stay and the widths a drag has moved past go.
///
/// Keyed on the proposal exactly as SwiftUI made it, not on the width it is laid out at, because
/// `TranscriptTextMeasure.size` reads the proposal as well as the layout, and a cache that is
/// keyed more loosely than the function it stands in for can answer a question it was never asked.
public struct TranscriptTextMeasureCache<Value> {
    public struct Key: Hashable, Sendable {
        public var proposed: Double?
        public var alignsBubbleInk: Bool

        public init(proposed: Double?, alignsBubbleInk: Bool) {
            self.proposed = proposed
            self.alignsBubbleInk = alignsBubbleInk
        }
    }

    /// Enough for every question one pass asks (zero, a hair, infinity, and nothing when a caller
    /// proposes none), the width the run is drawn at, the width the row measurer asks, and a little
    /// of a drag.
    public static var capacity: Int { 8 }

    private var entries: [(key: Key, value: Value)] = []

    public init() {}

    public var count: Int { entries.count }

    /// The answer to this question, if it has been given, which then counts as the most recent.
    public mutating func value(for key: Key) -> Value? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.value
    }

    public mutating func store(_ value: Value, for key: Key) {
        entries.removeAll { $0.key == key }
        if entries.count >= Self.capacity { entries.removeFirst(entries.count - Self.capacity + 1) }
        entries.append((key, value))
    }

    /// The text changed, so every answer is about text that is no longer there.
    public mutating func removeAll() {
        entries.removeAll()
    }
}

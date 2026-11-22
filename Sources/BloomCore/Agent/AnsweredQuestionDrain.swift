import Foundation

/// The queue move an answered permission question owes, carried until the window can make it.
///
/// **An answer is a moment the queue may move, and the window cannot act on it when it sees it.**
/// A message typed while a card was open is held by `DeliveryHold.question`, and on a backend that
/// takes a message mid turn it is due the moment the answer has been written, into the turn the
/// answer resumed. `TranscriptModel` reads the events of every runner with a presentation feed,
/// which is every runner, inside `consumePresentation`, and `drain` refuses for the whole of that.
/// So the drain the `.permissionDecided` handler asked for never ran, and the message waited for
/// the end of the turn and went as a turn of its own: seen on OpenCode in Bloom Dev on 2026-11-20,
/// and true of every backend. A result has the same problem and the pump raises it again once it
/// has caught up (`AgentPresentationReconciliation.permitsAutomaticDrain`); this is the answer's
/// half.
///
/// A batch rebuilt after an overflow carries no events, only the decisions read back from the
/// store, so an answer lost in one owes nothing here and the queue waits for the end of the turn.
public struct AnsweredQuestionDrain: Sendable, Equatable {
    private var isOwed = false

    public init() {}

    /// Records an answer among the batch's events. Kept until `take`, because the pump goes round
    /// again without acting while the feed is ahead of it.
    public mutating func note(_ batch: AgentPresentationBatch) {
        if batch.events.contains(where: Self.isAnswer) { isOwed = true }
    }

    /// Whether the window, caught up, drains now. Spent either way: the next answer owes another.
    ///
    /// Never for a turn that has stopped running, nor while a result waits to be finished: the
    /// queue is then the result's to move, or nobody's, since a launch and a Stop never move it
    /// (`TranscriptModel.drain`). Never while another question is open: it holds the queue, and
    /// its own answer owes the next move.
    public mutating func take(isTurnRunning: Bool, hasPendingResult: Bool, isAwaitingQuestion: Bool) -> Bool {
        defer { isOwed = false }
        return isOwed && isTurnRunning && !hasPendingResult && !isAwaitingQuestion
    }

    private static func isAnswer(_ event: AgentEvent) -> Bool {
        if case .permissionDecided = event { return true }
        return false
    }
}

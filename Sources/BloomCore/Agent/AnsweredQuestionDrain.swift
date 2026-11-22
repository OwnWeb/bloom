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
/// **Only an answer that leaves the turn running owes a move.** One that ends it leaves the queue
/// to the result, which starts the next turn with it. Moved on the answer instead, the send found
/// the refused turn still open: `TranscriptModel.deliver` took it for the same turn and opened no
/// history for the next one, the runner started that next turn behind it, and the pump, waiting on
/// the send, then read the refused turn's result as a past turn's. A question nobody answered owes
/// nothing either (`PermissionAskOutcome.wentUnanswered`). Stopped, quit and abandoned leave no
/// turn to move into; one the agent withdrew (`resolved-by-agent`, Codex's
/// `serverRequest/resolved`) may, but why it was withdrawn is not known here and was never
/// measured, so that queue waits for the end of the turn, as it did before.
///
/// A batch rebuilt after an overflow carries no events, only the decisions read back from the
/// store, so an answer lost in one owes nothing here and the queue waits for the end of the turn.
public struct AnsweredQuestionDrain: Sendable, Equatable {
    private static let deny = PermissionDecision.deny(message: "", endsTurn: false).storedName
    private static let denyAndStop = PermissionDecision.deny(message: "", endsTurn: true).storedName

    private var isOwed = false

    public init() {}

    /// Records an answer among the batch's events. Kept until `take`, because the pump goes round
    /// again without acting while the feed is ahead of it.
    public mutating func note(_ batch: AgentPresentationBatch, on agent: AgentKind) {
        if batch.events.contains(where: { Self.resumesTurn($0, on: agent) }) { isOwed = true }
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

    private static func resumesTurn(_ event: AgentEvent, on agent: AgentKind) -> Bool {
        guard case .permissionDecided(let resolution) = event else { return false }
        let decision = resolution.decision
        if PermissionAskOutcome.wentUnanswered(decision) || decision == denyAndStop { return false }
        return !(decision == deny && refusalEndsTurn(on: agent))
    }

    /// Whether a plain Deny ends the turn. Deny and stop ends it everywhere.
    ///
    /// OpenCode has one reject, and the prompt replies `cancelled` (`docs/OPENCODE.md`,
    /// Permissions). Claude Code and Codex hand the model the refusal and carry on
    /// (`docs/CODEX.md`). Grok and Cursor are unmeasured and answer `false` without consequence:
    /// neither takes a message mid turn, so a move owed there delivers nothing.
    private static func refusalEndsTurn(on agent: AgentKind) -> Bool {
        switch agent {
        case .openCode: true
        case .claudeCode, .codex, .grok, .cursor: false
        }
    }
}

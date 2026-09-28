import Foundation

/// A plan an agent proposed, read back out of the call that carried it, for the transcript to draw
/// as the document it is.
///
/// **It used to be a grey row, and the plan was hard to find.** Claude Code's `ExitPlanMode` and
/// Codex's plan item were both ordinary tool calls, so once the approval was answered they folded
/// into "N actions" with the reads around them, and opening the row showed the Markdown as plain
/// text: a JSON dump followed by the raw plan for Codex. Reported as "the plan is not shown after
/// the agent has completed the planning". The plan is the answer to what was asked, so it is kept
/// on screen as `TranscriptFold` keeps a sent message or a shown picture (its rule 2), and drawn
/// through the same Markdown renderer as the agent's prose.
///
/// Two spellings, one row. Claude Code's plan is the call's own `plan` input, whole when the call
/// arrives. Codex's call is filed as `Plan` when the item starts, empty, and the text arrives as
/// the item's result, so that one is read from the result.
public enum PlanRow {
    public static let claudeToolName = "ExitPlanMode"
    public static let codexToolName = "Plan"

    private static let probeLength = 1_024
    private static let markers = [claudeToolName, codexToolName].map { Data("\"name\":\"\($0)\"".utf8) }

    /// Whether a stored tool call is a plan, answered without decoding it.
    ///
    /// The name sits in the first few hundred bytes of both envelopes: Claude Code writes a
    /// block's `name` before its `input`, and a Codex plan call is stored when the item starts,
    /// before it has any text to push the name further in. Asked from the call's arrival, for the
    /// reason `MediaShowRow` gives: a row that became visible after being hidden would be the fold
    /// rearranging itself.
    public static func isCall(_ payload: Data) -> Bool {
        let head = payload.prefix(probeLength)
        return markers.contains { head.range(of: $0) != nil }
    }

    /// The plan's Markdown, or nil for any other call and for a plan with nothing in it yet.
    ///
    /// - Parameter resultText: the call's result, which is where Codex's plan is. Ignored for
    ///   Claude Code, whose result is the CLI's sentence about the approval.
    public static func markdown(of use: AgentToolUse, resultText: String?) -> String? {
        let text: String?
        switch use.name {
        case claudeToolName:
            text = use.input["plan"]?.stringValue
        case codexToolName where CodexTranslation.isCodexCall(use.input):
            text = resultText.flatMap { $0.isEmpty ? nil : $0 } ?? use.input["text"]?.stringValue
        default:
            return nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

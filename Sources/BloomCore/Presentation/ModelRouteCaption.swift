import Foundation

/// What the router's card says, and whether it is drawn at all.
///
/// The card sits over the top of a new workspace's conversation from the moment Create is pressed
/// until the first message goes: a spinner while Claude Haiku reads the task, its thinking under
/// the spinner as it is written, and then the model and effort it settled on. Every sentence on it
/// is here rather than in the view, so the suite can hold them to the house rules and to saying
/// something true in each of the four states.
public enum ModelRouteCaption {
    /// How much of the thinking the card shows. The newest part, because the card is watched while
    /// the text grows and the reader's eye is on its last line.
    public static let reasoningLimit = 320

    /// Whether the card is on screen.
    ///
    /// Always while the router is thinking, because that is the wait the card exists to explain.
    /// Once it has settled, until the conversation has its first row or the reader puts it away:
    /// past that point the composer's own chips say which model is running, and the session start
    /// row says it again, so a card repeating them would only cover the top of the transcript.
    public static func showsCard(isSettled: Bool, isDismissed: Bool, hasConversationStarted: Bool) -> Bool {
        guard isSettled else { return true }
        return !isDismissed && !hasConversationStarted
    }

    public static func title(route: ModelRoute?, isSettled: Bool) -> String {
        guard isSettled else { return "Choosing a model for this task" }
        guard let route else { return "Kept the model chosen in the window" }
        let model = ModelLabel.readable(route.model)
        guard !route.effort.isEmpty else { return model }
        return "\(model) \u{00B7} \(effortLabel(route.effort)) effort"
    }

    /// - Parameter analyser: the model reading the task, by the name its list gives it.
    public static func detail(route: ModelRoute?, isSettled: Bool, wasSkipped: Bool, analyser: String) -> String {
        guard isSettled else {
            return "\(analyser) is reading your message, not your code. The conversation starts "
                + "once it has chosen."
        }
        guard let route else {
            return wasSkipped
                ? "Skipped, so the first message goes on the model and effort the window was set to."
                : "The router did not answer, so the first message goes on the model and effort "
                    + "the window was set to."
        }
        guard !route.reason.isEmpty else { return "\(route.complexity.label) task." }
        return "\(route.complexity.label) task. \(route.reason)"
    }

    /// "Extra high" rather than "Xhigh", by the composer's own rule. See `CodexReasoningEffort`.
    public static func effortLabel(_ effort: String) -> String {
        CodexReasoningEffort(id: effort).label
    }

    /// The end of the thinking, on one paragraph, starting at a word.
    ///
    /// Newlines go because the card has four lines for this and a blank one between two thoughts
    /// would spend a quarter of them on nothing.
    public static func reasoningTail(_ reasoning: String, limit: Int = reasoningLimit) -> String {
        let flattened = reasoning
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }

        let tail = flattened.suffix(limit)
        let start = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
        return "\u{2026}" + String(tail[start...])
    }

    /// A table, in a sentence, for the footnote under the setting.
    public static func tableSummary(_ table: ModelRouterTable = .standard) -> String {
        let rungs = TaskComplexity.allCases.compactMap { rung -> String? in
            let choice = table.choice(for: rung)
            guard !choice.model.isEmpty else { return nil }
            let effort = choice.effort.isEmpty ? "" : ", \(effortLabel(choice.effort).lowercased())"
            return "\(rung.label): \(ModelLabel.readable(choice.model))\(effort)"
        }
        guard !rungs.isEmpty else { return "" }
        return rungs.joined(separator: ". ") + "."
    }

    /// What the create window says under its checkbox: who will read the task.
    public static func analyserNote(_ analyser: RouterAnalyser) -> String {
        "Read by \(analyser.name), on \(analyser.kind.label)."
    }

    /// What Settings says about an agent the analyser runs on, since the three cannot promise the
    /// same thing. See `ClaudeRouterAsk`, `CodexRouterAsk` and `GrokRouterAsk`.
    public static func safetyNote(for kind: AgentKind) -> String {
        switch kind {
        case .claudeCode:
            return "Claude Code reads the task with every tool switched off, in an empty folder."
        case .codex:
            return "Codex reads the task read-only, in an empty folder, with every approval refused. "
                + "It cannot be run with no tools at all, and starts your own MCP servers."
        case .grok:
            return "Grok reads the task in plan mode, in an empty folder, with every permission refused. "
                + "It cannot be run with no tools at all, and starts your own MCP servers."
        case .cursor, .openCode:
            return "\(kind.label) cannot read tasks for the router."
        }
    }
}

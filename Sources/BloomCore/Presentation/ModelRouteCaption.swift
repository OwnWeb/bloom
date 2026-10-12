import Foundation

/// What the router's card says, and whether it is drawn at all. Every sentence lives here rather
/// than in the view so the suite can hold each state to the house rules.
public enum ModelRouteCaption {
    /// The newest part, because the reader's eye is on the last line as the text grows.
    public static let reasoningLimit = 320

    /// Once settled, the card stays until the session start row takes over the decision, because the
    /// setup script can run for minutes before it.
    public static func showsCard(isSettled: Bool, isDismissed: Bool, hasSessionStarted: Bool) -> Bool {
        guard isSettled else { return true }
        return !isDismissed && !hasSessionStarted
    }

    public static func title(route: ModelRoute?, isSettled: Bool) -> String {
        guard isSettled else { return "Choosing a model for this task" }
        guard let route else { return "Kept the model this chat already had" }
        let model = ModelLabel.readable(route.model)
        guard !route.effort.isEmpty else { return model }
        return "\(model) \u{00B7} \(effortLabel(route.effort)) effort"
    }

    /// - Parameter readsOnlyTheMessage: true only for Claude Code, the one agent run with no tools
    ///   at all, so the card says no more than is true.
    public static func detail(
        route: ModelRoute?,
        isSettled: Bool,
        wasSkipped: Bool,
        analyser: String,
        readsOnlyTheMessage: Bool = true
    ) -> String {
        guard isSettled else {
            let reading = readsOnlyTheMessage ? "your message, not your code" : "your message"
            return "\(analyser) is reading \(reading). The conversation starts once it has chosen."
        }
        guard let route else {
            return wasSkipped
                ? "Skipped, so the first message keeps the model and effort it already had."
                : "The router did not answer, so the first message goes on the model and effort "
                    + "the window was set to."
        }
        guard !route.reason.isEmpty else { return "\(route.complexity.label) task." }
        return "\(route.complexity.label) task. \(route.reason)"
    }

    /// "Extra high" rather than "Xhigh". See `CodexReasoningEffort`.
    public static func effortLabel(_ effort: String) -> String {
        CodexReasoningEffort(id: effort).label
    }

    /// Newlines go because the card has four lines and a blank one would waste a quarter of them.
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

    /// The three agents cannot promise the same isolation. See `ClaudeRouterAsk`, `CodexRouterAsk`
    /// and `GrokRouterAsk`.
    public static func safetyNote(for kind: AgentKind) -> String {
        switch kind {
        case .claudeCode:
            return "Claude Code reads the task with every tool switched off, in an empty folder."
        case .codex:
            return "Codex reads the task in a read-only sandbox, in an empty folder, and every "
                + "command it asks approval for is refused. It cannot be run with no tools at all, "
                + "and starts your own MCP servers."
        case .grok:
            return "Grok reads the task in plan mode, in an empty folder, and every permission it "
                + "asks for is refused. Plan mode can still read files without asking, and Grok "
                + "starts your own MCP servers."
        case .cursor, .openCode:
            return "\(kind.label) cannot read tasks for the router."
        }
    }
}

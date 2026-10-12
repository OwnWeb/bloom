import Foundation

/// How much a task asks of the model, as the router reads it. Named rungs rather than a score,
/// and the routing prompt describes them in the same words, so answer and table share one scale.
public enum TaskComplexity: String, Sendable, Hashable, CaseIterable, Codable {
    case trivial
    case simple
    case moderate
    case complex
    case deep

    public var label: String {
        switch self {
        case .trivial: "Trivial"
        case .simple: "Simple"
        case .moderate: "Moderate"
        case .complex: "Complex"
        case .deep: "Deep"
        }
    }
}

/// Nothing builds one of these from raw model output except `ModelRouting.answer(from:)`.
public struct ModelRouterAnswer: Sendable, Hashable {
    public let complexity: TaskComplexity
    /// One line, possibly empty, shown under the decision and never sent anywhere.
    public let reason: String

    public init(complexity: TaskComplexity, reason: String) {
        self.complexity = complexity
        self.reason = reason
    }
}

/// The model and effort a new workspace's first chat starts on, and why.
public struct ModelRoute: Sendable, Hashable {
    public let complexity: TaskComplexity
    public let model: String
    /// Empty for a model that takes no effort, which is how the runner spells "send no `--effort`".
    public let effort: String
    public let reason: String

    public init(complexity: TaskComplexity, model: String, effort: String, reason: String) {
        self.complexity = complexity
        self.model = model
        self.effort = effort
        self.reason = reason
    }
}

/// The automatic router's rules: whether to ask, how to read the answer, what it turns into.
/// Pure, so the suite can hold every decision to the answers a model actually gives.
public enum ModelRouting {
    // MARK: - Whether to ask at all

    /// - Parameter isEnabled: the setting and the create window's Auto, which a manual pick turns off.
    /// - Parameter backend: never changed by the route, so a Codex chat is never handed `sonnet`.
    /// - Parameter isResuming: a resumed thread is not a new task.
    public static func shouldRoute(
        isEnabled: Bool,
        hasAnalyser: Bool,
        mode: WorkspaceStartMode,
        backend: AgentKind,
        prompt: String,
        isResuming: Bool
    ) -> Bool {
        guard isEnabled, !isResuming else { return false }
        guard offers(isEnabled: true, hasAnalyser: hasAnalyser, mode: mode, backend: backend) else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the create window offers Auto at all.
    public static func offers(isEnabled: Bool, hasAnalyser: Bool, mode: WorkspaceStartMode, backend: AgentKind) -> Bool {
        isEnabled && hasAnalyser && mode == .chat && backend.canRunWorkspaces
    }

    /// Only the model, the effort and the backend take the model back from the router; a
    /// permission mode or output style says nothing about which model should do the work.
    public static func takesOver(from before: ComposerControls, to after: ComposerControls) -> Bool {
        before.model != after.model || before.effort != after.effort || before.agentKind != after.agentKind
    }

    /// See `DeliveryHold.sentence(on:)` for the register.
    public static let holdSentence = "Goes once a model has been chosen."

    // MARK: - Reading the answer

    public static let reasonLimit = 200

    /// Nil keeps the model the chat was created with. Only a rung wrapped in quotes or punctuation
    /// is forgiven.
    public static func answer(from structured: JSONValue) -> ModelRouterAnswer? {
        guard let raw = structured["complexity"]?.stringValue else { return nil }
        let word = raw
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`.*")))
            .lowercased()
        guard let complexity = TaskComplexity(rawValue: word) else { return nil }
        return ModelRouterAnswer(
            complexity: complexity,
            reason: cleanReason(structured["reason"]?.stringValue) ?? ""
        )
    }

    /// One paragraph of plain text, capped at a word, or nothing.
    public static func cleanReason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Control characters become spaces, because deleting a tab between two words joins them.
        let flattened = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            $0.value < 0x20 || $0.value == 0x7F ? " " : $0
        }))
        let words = flattened.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        guard words.count > reasonLimit else { return words }

        let cut = words.prefix(reasonLimit)
        let kept = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(kept) + "\u{2026}"
    }

    // MARK: - Turning it into a model

    /// - Parameter current: on Claude Code, kept when it is the table choice's family, so somebody
    ///   on `opus[1m]` routed to `opus` keeps a million tokens of context.
    /// - Parameter models: the agent's last model list, empty when not asked. It only narrows.
    public static func route(
        _ answer: ModelRouterAnswer,
        table: ModelRouterTable = .standard,
        backend: AgentKind = .claudeCode,
        current: String,
        models: [AgentModel] = []
    ) -> ModelRoute {
        let choice = table.choice(for: answer.complexity)
        let model = chosenModel(choice.model, backend: backend, current: current, models: models)
        return ModelRoute(
            complexity: answer.complexity,
            model: model,
            effort: chosenEffort(choice.effort, model: model, backend: backend, models: models),
            reason: answer.reason
        )
    }

    static func chosenModel(_ wanted: String, backend: AgentKind, current: String, models: [AgentModel]) -> String {
        guard !wanted.isEmpty else { return current }
        let offered = models.filter { !$0.hidden }

        guard backend == .claudeCode else {
            // Codex and Grok ids are exact; one the list no longer offers keeps the current model.
            if !offered.isEmpty, !offered.contains(where: { $0.id == wanted }) { return current }
            return wanted
        }

        guard let wantedFamily = family(of: wanted) else { return wanted }
        if family(of: current) == wantedFamily { return current }

        // A list with nothing of this family is an account that cannot run it.
        if !offered.isEmpty, !offered.contains(where: { family(of: $0.id) == wantedFamily }) {
            return current
        }
        return wanted
    }

    static func chosenEffort(_ wanted: String, model: String, backend: AgentKind, models: [AgentModel]) -> String {
        let modelFamily = backend == .claudeCode ? family(of: model) : nil
        let entry = models.first { $0.id == model }
            ?? models.first { modelFamily != nil && family(of: $0.id) == modelFamily }
        guard let entry else { return wanted }
        // Listed with no levels is a model that takes no effort (Haiku today).
        guard !entry.supportedEfforts.isEmpty else { return "" }
        return entry.resolvedEffort(preferring: wanted)
    }

    /// Read the way `ModelAlias` reads one: `opus[1m]` and `claude-opus-5-5` are both Opus.
    public static func family(of id: String) -> String? {
        var name = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        return families.first { name == $0 || name.hasPrefix($0 + "-") || name.hasPrefix($0 + "[") }
    }

    private static let families = ["opus", "sonnet", "haiku", "fable"]
}

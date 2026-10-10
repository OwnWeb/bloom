import Foundation

/// How much a task asks of the model that will do it, as the router reads it.
///
/// Five rungs rather than a score, because a score invites a model to answer 6.5 and a reader to
/// wonder what a 3 is. Each rung names a kind of work somebody would recognise from their own week,
/// and the routing prompt describes them in the same words, so the answer and the table under it
/// cannot drift onto two different scales.
public enum TaskComplexity: String, Sendable, Hashable, CaseIterable, Codable {
    /// A typo, a rename, a one line configuration change, or a question about one file.
    case trivial
    /// A small change in one or two files with an obvious approach.
    case simple
    /// An ordinary feature or bug fix across a handful of files.
    case moderate
    /// Work across many files, a refactor, or a bug whose cause is not known yet.
    case complex
    /// Architecture, concurrency, security, performance or a migration: work where a wrong turn
    /// is expensive and deliberation pays for itself.
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

/// What the router said, once Bloom has decided it is usable. Nothing builds one of these from
/// raw model output except `ModelRouting.answer(from:)`.
public struct ModelRouterAnswer: Sendable, Hashable {
    public let complexity: TaskComplexity
    /// One line of plain text, possibly empty. Shown under the decision so the reader can see why,
    /// and never sent anywhere.
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
    /// Empty for a model that takes no effort at all, which is how the composer and the runner
    /// already spell "send no `--effort`".
    public let effort: String
    public let reason: String

    public init(complexity: TaskComplexity, model: String, effort: String, reason: String) {
        self.complexity = complexity
        self.model = model
        self.effort = effort
        self.reason = reason
    }
}

/// The automatic router's rules: whether to ask, how to read the answer, and what it turns into.
///
/// All of it is pure, for the reason `WorkspaceNaming` is: the process that asks is `ModelRouter`
/// and does no validation of its own, so everything that decides which model a first turn runs on
/// is here, where the suite can hold it to the answers a model actually gives, bad ones included.
public enum ModelRouting {
    // MARK: - Whether to ask at all

    /// Whether a workspace about to be created should have its first chat routed.
    ///
    /// - Parameter isEnabled: the setting, and the create window's own checkbox under it. The
    ///   window turns its checkbox off the moment a model or an effort is picked by hand, so a
    ///   choice somebody made is never overruled by a classifier. See `takesOver`.
    /// - Parameter hasAnalyser: whether any connected agent can read the task. See
    ///   `RouterAnalyser.resolve`, which is what answers it.
    /// - Parameter mode: only a Bloom chat. A CLI chat runs in a terminal with its own picker, and
    ///   a terminal or browser workspace has no turn to route.
    /// - Parameter backend: an agent Bloom can run a chat on. The route never changes it: the
    ///   table it is routed with is that agent's own, so a Codex chat is never handed `sonnet`.
    /// - Parameter prompt: empty gives the analyser nothing to read.
    /// - Parameter isResuming: Carry On picks up a conversation under the settings it was had
    ///   under, and a resumed thread is not a new task.
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

    /// Whether the create window shows the router's checkbox at all.
    public static func offers(isEnabled: Bool, hasAnalyser: Bool, mode: WorkspaceStartMode, backend: AgentKind) -> Bool {
        isEnabled && hasAnalyser && mode == .chat && backend.canRunWorkspaces
    }

    /// Whether a change made in the create window's footer takes the model back from the router.
    ///
    /// The model, the effort and the backend, and nothing else. A permission mode, an output style
    /// or fast mode picked in the footer says nothing about which model should do the work, and
    /// switching the router off because somebody chose Plan would be a surprise with no reason
    /// behind it.
    public static func takesOver(from before: ComposerControls, to after: ComposerControls) -> Bool {
        before.model != after.model || before.effort != after.effort || before.agentKind != after.agentKind
    }

    /// What the first pending bubble says while the router is still thinking. See
    /// `DeliveryHold.sentence(on:)` for the register.
    public static let holdSentence = "Goes once a model has been chosen."

    // MARK: - Reading the answer

    /// The longest reason the card is asked to carry. A model that writes a paragraph has
    /// misunderstood the question rather than been thorough.
    public static let reasonLimit = 200

    /// The answer out of the structured output, or nothing.
    ///
    /// Nil is a first class outcome: the caller keeps the model the chat was created with. An
    /// unknown rung, a missing one, or one wrapped in quotes and a full stop all end here, and only
    /// the last is forgiven.
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
        // Control characters become spaces rather than vanishing, for the reason
        // `WorkspaceNaming.cleanName` gives: deleting a tab between two words joins them.
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

    /// The route for an answer, given what the chat was going to run on and what its agent has.
    ///
    /// - Parameter table: the chat's own agent's table. See `ModelRouterSettings.table(for:models:)`.
    /// - Parameter backend: the chat's agent, which the route never changes.
    /// - Parameter current: the model the chat was created with. On Claude Code it is kept outright
    ///   when it is the same family as the table's choice, because the owner's own variant is a
    ///   choice the alias would throw away: somebody on `opus[1m]` routed to `opus` would lose a
    ///   million tokens of context to a decision about effort.
    /// - Parameter models: what the agent's model list last answered, empty when it has not been
    ///   asked. It only ever narrows: a model the account does not offer keeps `current`, and an
    ///   effort the chosen model does not take lands on the one it does.
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
        // A rung the table does not have.
        guard !wanted.isEmpty else { return current }
        let offered = models.filter { !$0.hidden }

        guard backend == .claudeCode else {
            // Codex and Grok ids are exact. One the list has stopped offering, which is a table
            // stored before a model was retired, keeps what the chat already had.
            if !offered.isEmpty, !offered.contains(where: { $0.id == wanted }) { return current }
            return wanted
        }

        guard let wantedFamily = family(of: wanted) else { return wanted }
        if family(of: current) == wantedFamily { return current }

        // A list that has answered and has nothing of this family is an account that cannot run
        // it. Staying where the chat already was is the one answer that is certain to start.
        if !offered.isEmpty, !offered.contains(where: { family(of: $0.id) == wantedFamily }) {
            return current
        }
        return wanted
    }

    static func chosenEffort(_ wanted: String, model: String, backend: AgentKind, models: [AgentModel]) -> String {
        let modelFamily = backend == .claudeCode ? family(of: model) : nil
        let entry = models.first { $0.id == model }
            ?? models.first { modelFamily != nil && family(of: $0.id) == modelFamily }
        // Not listed, or no list: the table's own level.
        guard let entry else { return wanted }
        // Listed with no levels at all is a model that takes no effort, which is Haiku today.
        // `ClaudeModel.agentModel` says the same thing by giving it an empty default.
        guard !entry.supportedEfforts.isEmpty else { return "" }
        return entry.resolvedEffort(preferring: wanted)
    }

    /// The Claude family an id belongs to, read the way `ModelAlias` reads one: `opus`,
    /// `opus[1m]`, `claude-opus-5-5` and `claude-opus-5[1m]` are all Opus.
    public static func family(of id: String) -> String? {
        var name = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        return families.first { name == $0 || name.hasPrefix($0 + "-") || name.hasPrefix($0 + "[") }
    }

    private static let families = ["opus", "sonnet", "haiku", "fable"]
}

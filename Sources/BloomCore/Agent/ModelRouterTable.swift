import Foundation

/// A model and a reasoning effort, in the words the chat's own CLI takes them.
public struct ModelRouteChoice: Sendable, Hashable, Codable {
    public var model: String
    /// Empty for a model that takes no effort, which is how the runners spell "send no effort".
    public var effort: String

    public init(model: String, effort: String) {
        self.model = model
        self.effort = effort
    }
}

/// Which model and effort each rung of `TaskComplexity` runs on, for one agent.
///
/// The analyser never names a model: it cannot know which models this account has or what the
/// owner will pay for, and a hallucinated id would fail a first turn nobody is watching. One table
/// per agent, because a route never changes agent. See `suggested(for:models:)`.
public struct ModelRouterTable: Sendable, Hashable {
    public var choices: [TaskComplexity: ModelRouteChoice]

    public init(choices: [TaskComplexity: ModelRouteChoice]) {
        self.choices = choices
    }

    /// Family aliases rather than versioned ids, so the table does not go stale when a model ships.
    /// Max is on no rung: a level that can turn a quick answer into a quarter of an hour should be
    /// somebody's decision rather than a classifier's.
    public static let standard = ModelRouterTable(choices: [
        .trivial: ModelRouteChoice(model: "haiku", effort: "medium"),
        .simple: ModelRouteChoice(model: "sonnet", effort: "high"),
        .moderate: ModelRouteChoice(model: "sonnet", effort: "xhigh"),
        .complex: ModelRouteChoice(model: "opus", effort: "high"),
        .deep: ModelRouteChoice(model: "opus", effort: "xhigh"),
    ])

    /// An empty model for a missing rung, which `ModelRouting.route` reads as "keep what the window
    /// was set to"; borrowing another table's model would put it on a backend that never heard of it.
    public func choice(for complexity: TaskComplexity) -> ModelRouteChoice {
        choices[complexity] ?? ModelRouteChoice(model: "", effort: "")
    }

    /// This table with the owner's own changes written over it, rung by rung.
    public func overriding(_ overrides: [TaskComplexity: ModelRouteChoice]) -> ModelRouterTable {
        ModelRouterTable(choices: choices.merging(overrides) { _, owner in owner })
    }

    // MARK: - Suggested tables

    /// Claude Code gets `standard`, because its aliases always resolve. Codex and Grok are read off
    /// the list (most capable first): the lower two rungs go to the newest light model, the upper
    /// three to the flagship. Nil when there is nothing to read.
    public static func suggested(for kind: AgentKind, models: [AgentModel]) -> ModelRouterTable? {
        switch kind {
        case .claudeCode:
            return standard
        case .codex, .grok:
            let offered = models.filter { !$0.hidden }
            guard let flagship = offered.first(where: { !RouterLightModels.isLight($0.id, on: kind) })
                ?? offered.first
            else { return nil }
            let light = offered.first { RouterLightModels.isLight($0.id, on: kind) } ?? flagship
            return ModelRouterTable(choices: [
                .trivial: rung(light, preferring: ["low", "minimal", "medium"]),
                .simple: rung(light, preferring: ["medium", "low", "high"]),
                .moderate: rung(flagship, preferring: ["medium", "low", "high"]),
                .complex: rung(flagship, preferring: ["high", "medium", "xhigh"]),
                .deep: rung(flagship, preferring: ["xhigh", "high", "medium"]),
            ])
        case .cursor, .openCode:
            return nil
        }
    }

    /// By level name rather than list position, because lists are ordered differently and a position
    /// would put `ultra` on a rung by accident.
    static func rung(_ model: AgentModel, preferring levels: [String]) -> ModelRouteChoice {
        guard !model.supportedEfforts.isEmpty else { return ModelRouteChoice(model: model.id, effort: "") }
        let taken = Set(model.supportedEfforts.map(\.id))
        let effort = levels.first { taken.contains($0) } ?? model.resolvedEffort(preferring: levels[0])
        return ModelRouteChoice(model: model.id, effort: effort)
    }
}

/// Which of an agent's models count as light, read off the vendors' own naming words because
/// nothing else in an id says anything about size.
public enum RouterLightModels {
    static let grokWords = ["fast", "mini", "nano", "lite", "small"]

    public static func isLight(_ id: String, on kind: AgentKind) -> Bool {
        switch kind {
        case .claudeCode:
            return ModelRouting.family(of: id) == "haiku"
        case .codex:
            return CodexModelRank.isReduced(id)
        case .grok, .cursor, .openCode:
            let words = id.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return words.contains { grokWords.contains($0) }
        }
    }
}

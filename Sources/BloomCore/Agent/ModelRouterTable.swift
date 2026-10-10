import Foundation

/// A model and a reasoning effort, in the words the chat's own CLI takes them.
///
/// Codable because the owner's own changes to a table are stored. See `ModelRouterSettings`.
public struct ModelRouteChoice: Sendable, Hashable, Codable {
    public var model: String
    /// Empty for a model that takes no effort at all, which is how the composer and the runners
    /// already spell "send no effort".
    public var effort: String

    public init(model: String, effort: String) {
        self.model = model
        self.effort = effort
    }
}

/// Which model and effort each rung of `TaskComplexity` runs on, for one agent.
///
/// **The router never names a model, and that is the design.** The analyser is asked one question
/// it can answer from the text alone, how much the task asks, and a table turns the answer into a
/// model. Asking it for a model id instead would hand it two things it cannot know: which models
/// this account has, and what the owner is prepared to pay for. It would also put a hallucinated
/// id one step from the CLI, where a first turn fails and nobody is watching. A fixed vocabulary in
/// and a fixed table out is what makes the route something the suite can pin down.
///
/// **One table per agent, because a route never changes agent.** The chat runs on the agent the
/// create window was set to, and the table for that agent picks among its own models. Claude
/// Code's is written down; Codex's and Grok's are read off the models the account actually has,
/// because their lists are fetched and change without Bloom being told. See `suggested(for:models:)`.
public struct ModelRouterTable: Sendable, Hashable {
    public var choices: [TaskComplexity: ModelRouteChoice]

    public init(choices: [TaskComplexity: ModelRouteChoice]) {
        self.choices = choices
    }

    /// Claude Code's table.
    ///
    /// The family aliases rather than versioned ids, because the CLI resolves an alias to whatever
    /// that family's current build is: the table does not go stale when a model ships. Two rungs
    /// share Sonnet and two share Opus, with the effort telling them apart, because the step from
    /// one model to the next is the expensive one and the effort is the cheap knob. Max is on no
    /// rung: it is the one level that can turn a quick answer into a quarter of an hour, and
    /// choosing that should be somebody's decision rather than a classifier's.
    public static let standard = ModelRouterTable(choices: [
        .trivial: ModelRouteChoice(model: "haiku", effort: "low"),
        .simple: ModelRouteChoice(model: "sonnet", effort: "medium"),
        .moderate: ModelRouteChoice(model: "sonnet", effort: "high"),
        .complex: ModelRouteChoice(model: "opus", effort: "high"),
        .deep: ModelRouteChoice(model: "opus", effort: "xhigh"),
    ])

    /// The choice for one rung.
    ///
    /// An empty model for a rung the table does not have, which `ModelRouting.route` reads as
    /// "keep what the window was set to". Falling back to another rung's model, or to Claude's
    /// table, would put a model on a backend that has never heard of it.
    public func choice(for complexity: TaskComplexity) -> ModelRouteChoice {
        choices[complexity] ?? ModelRouteChoice(model: "", effort: "")
    }

    /// This table with the owner's own changes written over it, rung by rung.
    public func overriding(_ overrides: [TaskComplexity: ModelRouteChoice]) -> ModelRouterTable {
        ModelRouterTable(choices: choices.merging(overrides) { _, owner in owner })
    }

    // MARK: - Suggested tables

    /// The table Bloom suggests for an agent, from the models its list last answered with.
    ///
    /// - Claude Code: `standard`, whatever the list says, because its aliases always resolve.
    /// - Codex and Grok: read off the list, which arrives most capable first. The two lower rungs
    ///   go to the newest reduced model (`mini`, `nano`, `fast` and the like), and the three upper
    ///   ones to the most capable full model, with the effort climbing by name. An account with no
    ///   reduced model runs every rung on the full one and lets the effort do the work.
    /// - Nil when there is nothing to read: a list that has not answered, or an agent with no
    ///   runner. The router then keeps what the window was set to.
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

    /// One rung on one model, at the first of the named levels the model takes.
    ///
    /// By name rather than by position in the model's list, because the lists are not ordered the
    /// same way everywhere and a position would put `ultra` on a rung by accident. A model whose
    /// list names none of these lands on its own default, and a model with no levels at all is
    /// sent none.
    static func rung(_ model: AgentModel, preferring levels: [String]) -> ModelRouteChoice {
        guard !model.supportedEfforts.isEmpty else { return ModelRouteChoice(model: model.id, effort: "") }
        let taken = Set(model.supportedEfforts.map(\.id))
        let effort = levels.first { taken.contains($0) } ?? model.resolvedEffort(preferring: levels[0])
        return ModelRouteChoice(model: model.id, effort: effort)
    }
}

/// Which of an agent's models count as light: cheap and quick enough to run on every task.
///
/// Read off the vendors' own words, because those are the only thing in a model's name that says
/// anything about its size. Codex's list is `CodexModelRank.reduced`, the same words that rank a
/// reduced model below a full one in the picker. Grok's adds `fast`, which is how xAI names the
/// models it means for this. Claude's is a family rather than a suffix: Haiku.
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

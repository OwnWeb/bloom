import Foundation

/// The agent and model that read a task and judge how much it asks.
///
/// Chosen among connected agents rather than installed ones, because a signed-out CLI answers
/// every question with a sign-in error. The check is local, so an expired token still counts
/// and fails like any other failure.
public struct RouterAnalyser: Sendable, Hashable {
    public var kind: AgentKind
    /// Empty for the agent's own default model, used before its model list has answered.
    public var model: String
    public var effort: String
    public var name: String

    public init(kind: AgentKind, model: String, effort: String, name: String) {
        self.kind = kind
        self.model = model
        self.effort = effort
        self.name = name
    }

    // MARK: - Choosing one

    /// Who analyses a task for a chat on `chatBackend`, or nil when nobody can. A named agent that is
    /// not connected falls back to following the chat rather than to nothing.
    public static func resolve(
        chatBackend: AgentKind,
        settings: ModelRouterSettings,
        connected: Set<AgentKind>,
        models: [AgentKind: [AgentModel]]
    ) -> RouterAnalyser? {
        let candidates = AgentKind.runnable.filter { connected.contains($0) }
        guard !candidates.isEmpty else { return nil }

        let kind: AgentKind
        if case .agent(let wanted) = settings.analyser, candidates.contains(wanted) {
            kind = wanted
        } else if candidates.contains(chatBackend) {
            kind = chatBackend
        } else {
            kind = candidates[0]
        }
        return analyser(on: kind, stored: settings.analyserModels[kind], models: models[kind] ?? [])
    }

    /// The owner's model while the list still offers it, otherwise the suggestion, at the owner's
    /// effort when the model takes it.
    public static func analyser(on kind: AgentKind, stored: ModelRouteChoice?, models: [AgentModel]) -> RouterAnalyser {
        let model: String
        if let stored, !stored.model.isEmpty, isOffered(stored.model, on: kind, in: models) {
            model = stored.model
        } else {
            model = suggestedModel(for: kind, models: models)
        }
        let listed = Self.entry(for: model, on: kind, in: models)
        let effort: String
        if let stored, stored.model == model, isTaken(stored.effort, by: listed) {
            effort = stored.effort
        } else {
            effort = readingEffort(of: listed)
        }
        return RouterAnalyser(kind: kind, model: model, effort: effort, name: name(of: model, on: kind, entry: listed))
    }

    /// Haiku on Claude Code; elsewhere the first light model listed, else the last (least capable)
    /// model, else empty for the agent's own default.
    public static func suggestedModel(for kind: AgentKind, models: [AgentModel]) -> String {
        if kind == .claudeCode { return "haiku" }
        let offered = models.filter { !$0.hidden }
        return (offered.first { RouterLightModels.isLight($0.id, on: kind) } ?? offered.last)?.id ?? ""
    }

    /// `high` where the model takes it: the answer decides what a whole conversation costs, and on
    /// Haiku `high` cost under a second more than `medium`.
    static func readingEffort(of entry: AgentModel?) -> String {
        guard let entry else { return "high" }
        let taken = entry.supportedEfforts.map(\.id)
        guard !taken.isEmpty else { return "" }
        return ["high", "medium", "low", "minimal"].first { taken.contains($0) } ?? taken[0]
    }

    // MARK: - Reading a list

    static func isOffered(_ model: String, on kind: AgentKind, in models: [AgentModel]) -> Bool {
        let offered = models.filter { !$0.hidden }
        guard !offered.isEmpty else { return true }
        return entry(for: model, on: kind, in: offered) != nil
            || (kind == .claudeCode && ModelRouting.family(of: model) != nil)
    }

    /// For Claude Code, the first entry of the family, since the list may spell `haiku` as
    /// `claude-haiku-4-5`.
    static func entry(for model: String, on kind: AgentKind, in models: [AgentModel]) -> AgentModel? {
        if let exact = models.first(where: { $0.id == model }) { return exact }
        guard kind == .claudeCode, let family = ModelRouting.family(of: model) else { return nil }
        return models.first { ModelRouting.family(of: $0.id) == family }
    }

    static func isTaken(_ effort: String, by entry: AgentModel?) -> Bool {
        guard let entry else { return true }
        if entry.supportedEfforts.isEmpty { return effort.isEmpty }
        return entry.supportedEfforts.contains { $0.id == effort }
    }

    static func name(of model: String, on kind: AgentKind, entry: AgentModel?) -> String {
        if let entry, !entry.displayName.isEmpty { return entry.displayName }
        guard !model.isEmpty else { return "\(kind.label)'s default model" }
        let readable = ModelLabel.readable(model)
        return kind == .claudeCode ? "Claude \(readable)" : readable
    }
}

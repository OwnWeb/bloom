import Foundation

/// The agent and model that read a task and judge how much it asks: Claude Haiku by default on a
/// Claude Code chat, a reduced Codex model on a Codex one, a fast Grok model on a Grok one.
///
/// **Which agent is a question of what is connected, not of what is installed.** A CLI with no
/// account signed in answers every question with a sign-in error, and a router that spent its wait
/// on that would hold the opening message for nothing. Connected is `AgentStatus.Connection`'s
/// own word for it: the binary found and an account configured, read from the files each CLI keeps
/// its sign-in in. The check is local, so an expired token still counts, and the call then fails
/// the way every other failure does: the chat keeps what the window was set to.
public struct RouterAnalyser: Sendable, Hashable {
    public var kind: AgentKind
    /// Empty for the agent's own default model, which is what a Codex or Grok analyser asks on
    /// when the list of models has not answered yet.
    public var model: String
    /// Empty for a model that takes no effort, or one whose levels are not known yet.
    public var effort: String
    /// What the card and the create window call it: the list's own name for the model, or a
    /// tidied id when the list has not answered.
    public var name: String

    public init(kind: AgentKind, model: String, effort: String, name: String) {
        self.kind = kind
        self.model = model
        self.effort = effort
        self.name = name
    }

    // MARK: - Choosing one

    /// Who analyses a task for a chat on `chatBackend`, or nil when nobody can.
    ///
    /// - Parameter settings: the owner's choices. Following the chat is the default, and a named
    ///   agent that is not connected falls back to the same rule rather than to nothing: a
    ///   preference for Codex on a machine that has signed out of it is still a wish for routing.
    /// - Parameter connected: the agents whose CLI is installed and signed in. Only those Bloom can
    ///   run a conversation with are ever chosen.
    /// - Parameter models: what each agent's list last answered, possibly nothing at all.
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

    /// The analyser on one agent: the owner's model while the list still offers it, otherwise the
    /// suggestion, at the owner's effort when the model takes it and the lightest one otherwise.
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
            effort = lightestEffort(of: listed)
        }
        return RouterAnalyser(kind: kind, model: model, effort: effort, name: name(of: model, on: kind, entry: listed))
    }

    /// The model Bloom suggests for reading tasks on an agent.
    ///
    /// Claude Code: Haiku, by its alias, which the CLI always resolves. Codex and Grok: the first
    /// light model their list offers, which is the newest one, since the lists arrive most capable
    /// first; failing that the last model on the list, which is the least capable; failing that
    /// nothing, which asks on the agent's own default.
    public static func suggestedModel(for kind: AgentKind, models: [AgentModel]) -> String {
        if kind == .claudeCode { return "haiku" }
        let offered = models.filter { !$0.hidden }
        return (offered.first { RouterLightModels.isLight($0.id, on: kind) } ?? offered.last)?.id ?? ""
    }

    /// The cheapest thinking a model offers that still thinks: `low` before `minimal`, because a
    /// model that does not reason at all has nothing for the card to show under its spinner.
    static func lightestEffort(of entry: AgentModel?) -> String {
        guard let entry else { return "low" }
        let taken = entry.supportedEfforts.map(\.id)
        guard !taken.isEmpty else { return "" }
        return ["low", "minimal", "medium"].first { taken.contains($0) } ?? taken[0]
    }

    // MARK: - Reading a list

    static func isOffered(_ model: String, on kind: AgentKind, in models: [AgentModel]) -> Bool {
        let offered = models.filter { !$0.hidden }
        guard !offered.isEmpty else { return true }
        return entry(for: model, on: kind, in: offered) != nil
            || (kind == .claudeCode && ModelRouting.family(of: model) != nil)
    }

    /// The list's entry for a model: its own id, or for Claude Code the first entry of its family,
    /// since `haiku` is an alias the list may spell `claude-haiku-4-5`.
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

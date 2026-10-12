import Foundation

/// The model, effort and backend somebody last picked in a composer footer, kept so the next
/// workspace opens on it rather than on whatever Settings says.
///
/// **It sits between the two things that already exist.** A default preset is a statement that
/// every new chat should start there, so it still wins. Settings, Models is the standing default
/// and this overrides it, because a choice made a minute ago is better evidence of what somebody
/// wants than a choice made at onboarding. A repository's own `models.default` still outranks
/// both, which `ComposerDefaults.resolve` already guarantees by reading the repository first.
///
/// Only the three fields that name a model are kept. The permission mode and the output style are
/// about how a chat behaves rather than what runs it, and carrying them from one workspace to the
/// next would quietly widen what an agent is allowed to do.
public struct LastModelChoice: Codable, Equatable, Sendable {
    public static let key = "composer.lastModelChoice"

    public var model: String
    public var effort: String
    /// Stored beside the model for the reason `AppDefaults.backend` is: Codex's list is fetched,
    /// and a new workspace has to open on the right CLI before, or without, that fetch.
    public var backend: AgentKind

    public init(model: String, effort: String, backend: AgentKind) {
        self.model = model
        self.effort = effort
        self.backend = backend
    }

    public init(_ controls: ComposerControls) {
        self.init(model: controls.model, effort: controls.effort, backend: controls.agentKind)
    }

    public static func load(from store: Store) async -> LastModelChoice? {
        guard let raw = try? await store.setting(key), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(LastModelChoice.self, from: data)
    }

    public func save(to store: Store) async throws {
        let data = try JSONEncoder().encode(self)
        try await store.setSetting(Self.key, String(decoding: data, as: UTF8.self))
    }
}

public extension AppDefaults {
    /// These defaults with the last footer choice written over the model, the effort and the
    /// backend. The stored fields move too, for the reason `applying(_ preset:)` gives: they are
    /// what `ComposerDefaults.resolve` reads to decide whether anything was chosen.
    func applying(_ choice: LastModelChoice) -> AppDefaults {
        var next = self
        next.model = choice.model
        next.storedModel = choice.model
        next.effort = choice.effort
        next.storedEffort = choice.effort
        next.backend = choice.backend
        return next
    }
}

/// Whether a model can be offered to somebody who may not have it.
///
/// **Only Codex can be asked, and only once its list has arrived.** Codex's `model/list` is
/// authoritative for its own ids, and a model that is not on the list the signed in account
/// fetched is one the account cannot run. Claude Code's ids cannot be checked the same way:
/// `opus-5-1m` is a real id no list holds. And an empty list means the fetch has not answered, not
/// that nothing is allowed, so it never disqualifies anything: a default that changed while a list
/// loads would be worse than one that was occasionally wrong.
public enum ModelAvailability {
    public static func isUsable(
        model: String,
        on kind: AgentKind,
        models: [AgentKind: [AgentModel]]
    ) -> Bool {
        guard kind == .codex, let list = models[kind], !list.isEmpty else { return true }
        let id = ModelIdentifier.resolve(model, models: models).model
        return list.contains { $0.id == id }
    }
}

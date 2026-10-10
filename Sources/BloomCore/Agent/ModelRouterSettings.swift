import Foundation

/// How the automatic router is set up, beyond whether it is on: which agent analyses, on which of
/// its models, and the owner's own changes to each agent's table.
///
/// Every field is an override of something Bloom can work out for itself, which is why the empty
/// value is the right one for nearly everybody: the chat's own agent analyses, on the model
/// `RouterAnalyser.suggestedModel` picks, and each table is `ModelRouterTable.suggested`. Storing
/// only the differences is what lets a suggestion improve when an agent's list does, rather than
/// pinning whatever the list said the day Settings was first opened.
public struct ModelRouterSettings: Sendable, Equatable {
    /// Which agent analyses a task.
    public enum Analyser: Sendable, Hashable {
        /// The agent the chat is on, or the first connected one when that one is not.
        case followChat
        /// This agent, whatever the chat is on, while it is connected.
        case agent(AgentKind)
    }

    public var analyser: Analyser
    /// The model and effort each agent analyses on, where the owner chose one.
    public var analyserModels: [AgentKind: ModelRouteChoice]
    /// The owner's own rungs, per agent, over the suggested table.
    public var tables: [AgentKind: [TaskComplexity: ModelRouteChoice]]

    public init(
        analyser: Analyser = .followChat,
        analyserModels: [AgentKind: ModelRouteChoice] = [:],
        tables: [AgentKind: [TaskComplexity: ModelRouteChoice]] = [:]
    ) {
        self.analyser = analyser
        self.analyserModels = analyserModels
        self.tables = tables
    }

    /// The table a chat on `kind` is routed with: the suggestion, with the owner's rungs over it.
    /// Nil when there is neither, which keeps the chat on what the window was set to.
    public func table(for kind: AgentKind, models: [AgentModel]) -> ModelRouterTable? {
        let overrides = tables[kind] ?? [:]
        guard let suggested = ModelRouterTable.suggested(for: kind, models: models) else {
            return overrides.isEmpty ? nil : ModelRouterTable(choices: overrides)
        }
        return suggested.overriding(overrides)
    }
}

// MARK: - Storage

/// The stored shape, with string keys.
///
/// A dictionary keyed by an enum encodes as a flat array of alternating keys and values unless the
/// key is a `String`, which reads back but cannot be read by anybody opening the preference to see
/// what it says. Raw values as keys are what make the stored JSON say what it means.
private struct StoredRouterSettings: Codable {
    var analyser: String?
    var analyserModels: [String: ModelRouteChoice]?
    var tables: [String: [String: ModelRouteChoice]]?
}

extension ModelRouterSettings {
    /// The stored word for "follow the chat". Any agent is stored as its raw value.
    static let followChatWord = "chat"

    /// Anything that does not decode, a rung or an agent from a later version among them, is left
    /// out rather than failing the whole value: the router's settings are a convenience, and a
    /// stale entry must not switch the owner's other choices back to the defaults.
    public static func decode(_ raw: String?) -> ModelRouterSettings {
        guard let raw, let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredRouterSettings.self, from: data)
        else { return ModelRouterSettings() }

        let analyser: Analyser = stored.analyser.flatMap(AgentKind.init(rawValue:)).map(Analyser.agent) ?? .followChat
        var models: [AgentKind: ModelRouteChoice] = [:]
        for (key, choice) in stored.analyserModels ?? [:] {
            if let kind = AgentKind(rawValue: key) { models[kind] = choice }
        }
        var tables: [AgentKind: [TaskComplexity: ModelRouteChoice]] = [:]
        for (key, rungs) in stored.tables ?? [:] {
            guard let kind = AgentKind(rawValue: key) else { continue }
            var table: [TaskComplexity: ModelRouteChoice] = [:]
            for (rung, choice) in rungs {
                if let complexity = TaskComplexity(rawValue: rung) { table[complexity] = choice }
            }
            if !table.isEmpty { tables[kind] = table }
        }
        return ModelRouterSettings(analyser: analyser, analyserModels: models, tables: tables)
    }

    /// Nil for the empty value, so a reset removes the preference rather than storing nothing.
    public func encoded() -> String? {
        guard self != ModelRouterSettings() else { return nil }
        let analyserWord: String
        switch analyser {
        case .followChat: analyserWord = Self.followChatWord
        case .agent(let kind): analyserWord = kind.rawValue
        }
        let stored = StoredRouterSettings(
            analyser: analyserWord,
            analyserModels: Dictionary(uniqueKeysWithValues: analyserModels.map { ($0.key.rawValue, $0.value) }),
            tables: Dictionary(uniqueKeysWithValues: tables.map { kind, rungs in
                (kind.rawValue, Dictionary(uniqueKeysWithValues: rungs.map { ($0.key.rawValue, $0.value) }))
            })
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Whether new workspaces ask the router, and how it is set up, as preferences.
///
/// **Off by default, which is the opposite of the namer's answer, and the difference is the
/// point.** Naming changes a label; routing changes which model does the work, what it costs, and
/// how long the first turn takes to start, since the opening message waits for the answer. That
/// is a trade somebody should opt into knowing it is being made.
///
/// `@unchecked Sendable` for the reason `WorkspaceNamingPreferences` gives: `UserDefaults` is
/// thread safe and not annotated, and there is no other state here.
public struct ModelRouterPreferences: @unchecked Sendable {
    public static let key = "router.workspaces"
    public static let settingsKey = "router.settings"
    public static let fallback = false

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? Self.fallback }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    public var settings: ModelRouterSettings {
        get { ModelRouterSettings.decode(defaults.string(forKey: Self.settingsKey)) }
        nonmutating set {
            if let raw = newValue.encoded() {
                defaults.set(raw, forKey: Self.settingsKey)
            } else {
                defaults.removeObject(forKey: Self.settingsKey)
            }
        }
    }
}

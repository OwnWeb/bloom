import Foundation

/// Which agent analyses, on which model, and the owner's changes to each agent's table.
///
/// Every field is an override, empty for nearly everybody. Storing only the differences lets a
/// suggestion improve when an agent's list does, rather than pinning the list of the day.
public struct ModelRouterSettings: Sendable, Equatable {
    public enum Analyser: Sendable, Hashable {
        /// The chat's agent, or the first connected one when that one is not.
        case followChat
        case agent(AgentKind)
    }

    public var analyser: Analyser
    public var analyserModels: [AgentKind: ModelRouteChoice]
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

    /// Nil when there is neither suggestion nor override, which keeps what the window was set to.
    public func table(for kind: AgentKind, models: [AgentModel]) -> ModelRouterTable? {
        let overrides = tables[kind] ?? [:]
        guard let suggested = ModelRouterTable.suggested(for: kind, models: models) else {
            return overrides.isEmpty ? nil : ModelRouterTable(choices: overrides)
        }
        return suggested.overriding(overrides)
    }
}

// MARK: - Storage

/// String keys, because a dictionary keyed by an enum encodes as an unreadable flat array.
private struct StoredRouterSettings: Codable {
    var analyser: String?
    var analyserModels: [String: ModelRouteChoice]?
    var tables: [String: [String: ModelRouteChoice]]?
}

extension ModelRouterSettings {
    static let followChatWord = "chat"

    /// Anything that does not decode (say, from a later version) is dropped rather than failing the
    /// whole value, so one stale entry cannot reset the owner's other choices.
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

    /// Nil for the empty value, so a reset removes the preference.
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
/// Off by default, unlike the namer: routing changes which model works, what it costs, and how
/// long the first turn waits, a trade somebody should opt into.
/// `@unchecked Sendable` because `UserDefaults` is thread safe but not annotated.
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

import Foundation

/// One model OpenCode offers, with the effort levels that model has.
///
/// Fetched, never hardcoded: the list is whatever providers the user connected.
public struct OpenCodeModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let isDefault: Bool
    public let efforts: [OpenCodeConfigOptions.Choice]
    public let defaultEffort: String

    public init(
        id: String,
        displayName: String = "",
        isDefault: Bool = false,
        efforts: [OpenCodeConfigOptions.Choice] = [],
        defaultEffort: String = ""
    ) {
        self.id = id
        self.displayName = displayName.isEmpty ? id : displayName
        self.isDefault = isDefault
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }

    public var agentModel: AgentModel {
        AgentModel(
            id: id,
            displayName: displayName,
            isDefault: isDefault,
            supportedEfforts: efforts.map { AgentModelEffort(id: $0.value, label: $0.name) },
            defaultEffort: defaultEffort
        )
    }
}

/// The models OpenCode offers, fetched once and kept.
///
/// `initialize` lists no models and `opencode models` goes through the background service, so the
/// list is read off a throwaway session: its `model` option names every model, and selecting each
/// one in turn returns that model's `effort` option. No prompt is sent, and the session is deleted
/// so nothing is left in the user's history. Measured on 2.3.2: thirteen models in 0.02 seconds.
public actor OpenCodeModelCatalog {
    private let cache: AgentModelCache<OpenCodeModel>

    public var fetchCount: Int { get async { await cache.fetchCount } }

    public init(
        fetch: @escaping @Sendable () async throws -> [OpenCodeModel],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        cache = AgentModelCache(fetch: fetch, now: now)
    }

    public static func live(
        cwd: String = AgentScratchDirectory.current(),
        store: Store? = nil,
        makeClient: @escaping @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient = OpenCodeRunner.spawn
    ) -> OpenCodeModelCatalog {
        OpenCodeModelCatalog(fetch: {
            let stored = try await store?.setting(AgentCatalog.executablePathSettingKey(.openCode))
            let client = makeClient(OpenCodeClient.Configuration(
                executable: AgentCatalog.executable(for: .openCode, override: stored),
                cwd: cwd
            ))
            defer { Task { await client.stop() } }
            try await client.start()
            return try await discover(on: client, cwd: cwd)
        })
    }

    static func discover(
        on client: OpenCodeClient, cwd: String, announcementWait: Duration = .seconds(5)
    ) async throws -> [OpenCodeModel] {
        let session = try await client.newSession(cwd: cwd)
        // The reply missed Ollama in four runs out of twenty; the last announcement after it had it.
        let listed = await client.latestAnnouncedOptions(after: announcementWait) ?? session.options
        var models: [OpenCodeModel] = []
        for choice in listed.models {
            // A model that cannot be selected is still listed, with no effort levels.
            let options = try? await client.setConfigOption(
                sessionID: session.id, configID: OpenCodeConfigOptions.modelID, value: choice.value
            )
            models.append(OpenCodeModel(
                id: choice.value,
                displayName: choice.name,
                isDefault: choice.value == session.options.currentModel,
                efforts: options?.efforts ?? [],
                defaultEffort: options?.currentEffort ?? ""
            ))
        }
        await client.deleteSession(session.id)
        return models
    }

    public func models() async throws -> [OpenCodeModel] {
        try await cache.models()
    }

    public func invalidate() async {
        await cache.invalidate()
    }

    public var lastKnown: [OpenCodeModel] { get async { await cache.lastKnown } }
}

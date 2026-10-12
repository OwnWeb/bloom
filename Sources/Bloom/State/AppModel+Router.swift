import BloomCore

/// The router's two decisions that need live state (who reads the task, which table applies),
/// in one place so the create window offering Auto and `startWorkspace` asking cannot disagree.
extension AppModel {
    struct OpeningRouter {
        let analyser: RouterAnalyser
        let table: ModelRouterTable
    }

    /// Nil when nothing signed in can read a task, or the chat's agent has no table yet (a Codex or
    /// Grok list that has not answered).
    func openingRouter(
        for backend: AgentKind,
        settings: ModelRouterSettings = ModelRouterPreferences().settings
    ) -> OpeningRouter? {
        let models = ComposerModelCatalog.shared.models
        guard let analyser = RouterAnalyser.resolve(
            chatBackend: backend,
            settings: settings,
            connected: AgentAvailability.shared.connected,
            models: models
        ), let table = settings.table(for: backend, models: models[backend] ?? []) else { return nil }
        return OpeningRouter(analyser: analyser, table: table)
    }
}

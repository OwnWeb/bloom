import BloomCore

/// The automatic router's two answers that need this app's live state rather than a value: who
/// reads the task, which comes from what is signed in, and which table the chat is routed with,
/// which comes from the models its agent's list last offered.
///
/// Both decisions are the core's (`RouterAnalyser.resolve` and `ModelRouterSettings.table`), and
/// this only hands them the two live readings, so the create window, which has to know whether to
/// offer the checkbox, and `startWorkspace`, which has to know whether to ask, cannot disagree.
extension AppModel {
    struct OpeningRouter {
        let analyser: RouterAnalyser
        let table: ModelRouterTable
    }

    /// Nil when nothing signed in can read a task, or when the chat's agent has no table yet,
    /// which is a Codex or Grok chat whose list of models has not answered.
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

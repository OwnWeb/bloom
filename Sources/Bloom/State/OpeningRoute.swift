import BloomCore
import Observation

/// The router's question about a new workspace's first chat: asked when Create is pressed, so the
/// analyser reads while git cuts the worktree, and joined to the chat by `settle(into:in:)`.
///
/// It holds the queue's drain, not the setup. Settling never drains: an analyser can fail before
/// the setup script starts, which once sent the opening message beside `composer install`. Not a
/// `DeliveryHold` case, because those are stored facts the bridge reads and this is in memory only.
@MainActor
@Observable
final class OpeningRoute {
    private(set) var progress = ModelRouterProgress()
    /// Nil while thinking, and for good when skipped or unanswered.
    private(set) var route: ModelRoute?
    /// Whether the first message may go: the route has been written to the chat, or given up on.
    private(set) var isSettled = false
    private(set) var wasSkipped = false
    private(set) var sessionID: SessionID?
    var isDismissed = false

    let analyser: RouterAnalyser

    @ObservationIgnored private var asking: Task<ModelRoute?, Never>?
    @ObservationIgnored private var applying: Task<Void, Never>?

    /// - Parameter controls: what the chat keeps if the router declines.
    /// - Parameter models: possibly empty; nothing waits for a fetch, an empty list only skips the
    ///   narrowing.
    init(
        task: String,
        project: String,
        controls: ComposerControls,
        analyser: RouterAnalyser,
        executable: String,
        table: ModelRouterTable,
        models: [AgentModel],
        router: ModelRouter = ModelRouter()
    ) {
        self.analyser = analyser
        let steps = router.progress(
            task: task,
            project: project,
            template: PromptOverrides().template(for: .routeTask),
            analyser: analyser,
            executable: executable
        )
        let current = controls.model
        let backend = controls.agentKind
        asking = Task { [weak self] () -> ModelRoute? in
            var last = ModelRouterProgress()
            for await step in steps {
                last = step
                self?.progress = step
            }
            // An answer landing in the same breath as Skip is still skipped.
            guard !Task.isCancelled, let answer = last.answer else { return nil }
            return ModelRouting.route(answer, table: table, backend: backend, current: current, models: models)
        }
    }

    /// Applies through `TranscriptModel.updatePreferences`, so the first delivery's runner is built
    /// on the routed model, then syncs the workspace's session list as `ComposerSessionEditor.apply`
    /// does, so the strip does not describe the old model. A model or effort picked in the composer
    /// while the analyser reads wins, as a Skip would.
    func settle(into transcript: TranscriptModel, in workspace: WorkspaceModel) {
        guard applying == nil else { return }
        sessionID = transcript.session.id
        let startedOn = [transcript.session.model, transcript.session.effort]
        applying = Task { [weak self, weak transcript, weak workspace] in
            guard let self else { return }
            var answer: ModelRoute?
            if let asking = self.asking { answer = await asking.value }
            guard !Task.isCancelled else { return }
            if let transcript, [transcript.session.model, transcript.session.effort] != startedOn {
                answer = nil
                self.wasSkipped = true
            }
            if let answer, let transcript {
                await transcript.updatePreferences(model: answer.model, effort: answer.effort)
                if let workspace, let index = workspace.sessions.firstIndex(where: { $0.id == transcript.session.id }) {
                    workspace.sessions[index] = transcript.session
                }
                await transcript.record(ModelRouteNote(route: answer, analyser: self.analyser.name))
            }
            self.route = answer
            self.isSettled = true
        }
    }

    /// Returns at once when the route never joined a chat. `WorkspaceModel.runSetupThenSend` awaits
    /// this before its drain.
    func settled() async {
        guard let applying else { return }
        await applying.value
    }

    func skip() {
        guard !isSettled else { return }
        wasSkipped = true
        asking?.cancel()
    }

    /// Settled as well as stopped: an archive can be refused after stopping everything, and an
    /// unsettled route would then keep the first chat's queue shut for good.
    func cancel() {
        asking?.cancel()
        applying?.cancel()
        isSettled = true
    }

    func holds(_ id: SessionID) -> Bool {
        !isSettled && sessionID == id
    }
}

import BloomCore
import Observation

/// The automatic router's question about one new workspace's first chat: asked when Create is
/// pressed, answered while the worktree is being cut, and applied before the opening message goes.
///
/// **Asked before the workspace exists, on purpose.** `AppModel.startWorkspace` builds this ahead
/// of `WorkspaceManager.start`, so Claude Haiku is reading the task while git cuts the worktree and
/// the setup script runs, and most of its eight to seventeen seconds are spent behind work that
/// was happening anyway. The chat it is for does not exist until `start` returns, which is why the
/// question and the applying are two halves: the question starts here, and `settle(into:)` joins
/// it to the chat once there is one.
///
/// **It holds the queue, not the setup.** The opening message joins the chat's queue as it always
/// has and the setup script runs as it always has. What waits is the drain: `TranscriptModel`
/// reads `holds(_:)` and leaves the queue where it is until this has settled, and settling drains
/// it, because the route arriving is the moment the first message may go if setup is already done.
///
/// Not a case of `DeliveryHold`, although it reads like one. A hold there is a fact the bridge's
/// tools read off the stored rows, and this lives only in memory for a few seconds after Create:
/// widening that enum would have taught `workspace_list` and the merge tool about a wait that
/// cannot outlive the process that is having it.
@MainActor
@Observable
final class OpeningRoute {
    /// What the router has said so far, which is what the card draws.
    private(set) var progress = ModelRouterProgress()
    /// What was applied to the chat. Nil while the router is thinking, and for good when it was
    /// skipped or did not answer, in which case the chat keeps what the window was set to.
    private(set) var route: ModelRoute?
    /// Whether the first message may go: the route has been written to the chat, or given up on.
    private(set) var isSettled = false
    private(set) var wasSkipped = false
    /// The chat this is for, once the workspace exists.
    private(set) var sessionID: SessionID?
    /// Whether the reader has put the card away once there was nothing left to wait for.
    var isDismissed = false

    @ObservationIgnored private var asking: Task<ModelRoute?, Never>?
    @ObservationIgnored private var applying: Task<Void, Never>?

    /// Starts asking at once.
    ///
    /// - Parameter controls: what the window was set to, which is what the chat keeps if the
    ///   router declines, and whose model a same family answer keeps. See `ModelRouting.route`.
    /// - Parameter models: Claude Code's model list as the composer last fetched it, possibly
    ///   empty. Nothing waits for a fetch here: an empty list costs only the narrowing.
    init(
        task: String,
        project: String,
        controls: ComposerControls,
        models: [AgentModel],
        router: ModelRouter = ModelRouter(),
        table: ModelRouterTable = .standard
    ) {
        let steps = router.progress(
            task: task,
            project: project,
            template: PromptOverrides().template(for: .routeTask)
        )
        let current = controls.model
        asking = Task { [weak self] () -> ModelRoute? in
            var last = ModelRouterProgress()
            for await step in steps {
                last = step
                self?.progress = step
            }
            // Skip cancels this task, and an answer that lands in the same breath is still a
            // skipped one: the reader pressed the button because they wanted the window's choice.
            guard !Task.isCancelled, let answer = last.answer else { return nil }
            return ModelRouting.route(answer, table: table, current: current, models: models)
        }
    }

    /// Joins the question to the chat it is for, and applies the answer when it comes.
    ///
    /// Through `TranscriptModel.updatePreferences`, which is the composer's own door: it writes
    /// the two columns and nothing else, and refreshes the chat's copy of its row, so the runner
    /// that the first delivery builds is built on the routed model rather than on the one the
    /// window was set to. The create window has already marked the chat settled, so the composer's
    /// first-open defaults cannot put the old choice back afterwards.
    func settle(into transcript: TranscriptModel) {
        guard applying == nil else { return }
        sessionID = transcript.session.id
        applying = Task { [weak self, weak transcript] in
            guard let self else { return }
            var answer: ModelRoute?
            if let asking = self.asking { answer = await asking.value }
            guard !Task.isCancelled else { return }
            if let answer, let transcript {
                await transcript.updatePreferences(model: answer.model, effort: answer.effort)
            }
            self.route = answer
            self.isSettled = true
            // The fourth moment a queue is meant to move, beside the three `drain` names: the
            // route is the last thing the opening message was waiting for whenever setup finished
            // first. Harmless when setup is still running, since the drain reads that hold too.
            await transcript?.drain()
        }
    }

    /// Returns once the route has been applied or given up on, and at once when it never joined
    /// a chat. What `WorkspaceModel.runSetupThenSend` waits on before its drain.
    func settled() async {
        guard let applying else { return }
        await applying.value
    }

    /// Stops asking. The chat keeps what the window was set to, and its first message goes as
    /// soon as nothing else is holding it.
    func skip() {
        guard !isSettled else { return }
        wasSkipped = true
        asking?.cancel()
    }

    /// The workspace is going away, or never arrived. Stops the process and the applying both.
    func cancel() {
        asking?.cancel()
        applying?.cancel()
    }

    /// Whether this chat's queue has to wait for the router.
    func holds(_ id: SessionID) -> Bool {
        !isSettled && sessionID == id
    }
}

import BloomCore
import Observation

/// The automatic router's question about one new workspace's first chat: asked when Create is
/// pressed, answered while the worktree is being cut, and applied before the opening message goes.
///
/// **Asked before the workspace exists, on purpose.** `AppModel.startWorkspace` builds this ahead
/// of `WorkspaceManager.start`, so the analyser is reading the task while git cuts the worktree and
/// the setup script runs, and most of its wait is spent behind work that was happening anyway. The
/// chat it is for does not exist until `start` returns, which is why the question and the applying
/// are two halves: the question starts here, and `settle(into:in:)` joins it to the chat once there
/// is one.
///
/// **It holds the queue, not the setup.** The opening message joins the chat's queue as it always
/// has and the setup script runs as it always has. What waits is the drain: `TranscriptModel`
/// reads `holds(_:)` and leaves the queue where it is until this has settled, and
/// `WorkspaceModel.runSetupThenSend` awaits `settled()` before its own drain, so the first message
/// goes once both setup and the route are behind it.
///
/// **Settling does not drain, and it did.** A drain from here ran whenever the answer came, and an
/// answer can come before the setup script has even started: a signed out analyser fails in a
/// second, and `DeliveryHold.setup` only holds once the script is running. The opening message
/// then went out beside `composer install`, which is the race the queue exists to stop. The one
/// drain that follows setup is the one that knows setup is over.
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

    /// Who is reading the task, which is what the card names.
    let analyser: RouterAnalyser

    @ObservationIgnored private var asking: Task<ModelRoute?, Never>?
    @ObservationIgnored private var applying: Task<Void, Never>?

    /// Starts asking at once.
    ///
    /// - Parameter controls: what the window was set to, which is what the chat keeps if the
    ///   router declines, and whose model a same family answer keeps. See `ModelRouting.route`.
    /// - Parameter analyser: who reads the task, and `executable` the binary to run it with.
    /// - Parameter table: the chat's own agent's table. The route never changes agent.
    /// - Parameter models: the chat's agent's list as the composer last fetched it, possibly
    ///   empty. Nothing waits for a fetch here: an empty list costs only the narrowing.
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
            // Skip cancels this task, and an answer that lands in the same breath is still a
            // skipped one: the reader pressed the button because they wanted the window's choice.
            guard !Task.isCancelled, let answer = last.answer else { return nil }
            return ModelRouting.route(answer, table: table, backend: backend, current: current, models: models)
        }
    }

    /// Joins the question to the chat it is for, and applies the answer when it comes.
    ///
    /// Through `TranscriptModel.updatePreferences`, which is the composer's own door: it writes
    /// the two columns and nothing else, and refreshes the chat's copy of its row, so the runner
    /// that the first delivery builds is built on the routed model rather than on the one the
    /// window was set to. The create window has already marked the chat settled, so the composer's
    /// first-open defaults cannot put the old choice back afterwards.
    ///
    /// The workspace's own list of sessions is brought into step after, as
    /// `ComposerSessionEditor.apply` does for a pick in the footer: the strip and anything else
    /// that reads that list would otherwise go on describing the model the window was set to.
    func settle(into transcript: TranscriptModel, in workspace: WorkspaceModel) {
        guard applying == nil else { return }
        sessionID = transcript.session.id
        applying = Task { [weak self, weak transcript, weak workspace] in
            guard let self else { return }
            var answer: ModelRoute?
            if let asking = self.asking { answer = await asking.value }
            guard !Task.isCancelled else { return }
            if let answer, let transcript {
                await transcript.updatePreferences(model: answer.model, effort: answer.effort)
                if let workspace, let index = workspace.sessions.firstIndex(where: { $0.id == transcript.session.id }) {
                    workspace.sessions[index] = transcript.session
                }
            }
            self.route = answer
            self.isSettled = true
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
    ///
    /// Settled as well as stopped, with no route. An archive can be refused after it has stopped
    /// everything, and the workspace then lives on: left unsettled, `holds(_:)` would keep its
    /// first chat's queue shut for good, under a card that spins with nothing behind it.
    func cancel() {
        asking?.cancel()
        applying?.cancel()
        isSettled = true
    }

    /// Whether this chat's queue has to wait for the router.
    func holds(_ id: SessionID) -> Bool {
        !isSettled && sessionID == id
    }
}

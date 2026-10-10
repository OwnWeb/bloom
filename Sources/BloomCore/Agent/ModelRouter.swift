import Foundation

/// Asks a light model how much a task asks of the model that will do it, and is allowed to fail.
///
/// The question is the same whichever agent answers it, and so are the prompt, the deadline and
/// the way the answer is read: what differs is only how the question reaches the agent, which is
/// the adapter's job. `ClaudeRouterAsk` runs a `claude -p` with every tool off, `CodexRouterAsk`
/// opens one turn on a short-lived app-server, and `GrokRouterAsk` one prompt on a short-lived ACP
/// connection. Each turns what its agent says into `RouterSignal`s, and `ModelRouterProgress`
/// folds those into what the card draws.
///
/// Which agent and which model answer is `RouterAnalyser`'s decision, from what is connected and
/// what the owner chose. A light model by default, because the question is a reading of one
/// paragraph and the answer is worth having only if it arrives before the person who asked has
/// given up on it: a larger model would classify no better and would put its own cost on every
/// workspace, including the trivial ones the router exists to make cheaper.
public struct ModelRouter: Sendable {
    /// Asks one request and hands back its signals. Injected so the suite drives the whole path
    /// without a network, an account or a bill.
    public typealias Ask = @Sendable (ModelRouterRequest) -> AsyncThrowingStream<RouterSignal, Error>

    /// Replaces each agent's own system prompt, where the agent lets it be replaced. Short on
    /// purpose: the rungs and what they mean are in the editable prompt, and this only has to
    /// establish the shape of the reply. It names the JSON outright because only Claude Code can
    /// be made to answer through a schema; the other two are asked in words.
    public static let systemPrompt = """
    You triage coding tasks for an app that chooses which model will do them. Do not use any \
    tool and do not read any file. Think briefly, then answer with only the JSON object the task \
    asks for, with no commentary before or after it.
    """

    /// Forces the shape of the answer where the agent can be made to, built from `TaskComplexity`
    /// so the rungs the model may name and the rungs the table has can never disagree.
    public static let jsonSchema: String = {
        let rungs = TaskComplexity.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"complexity":{"type":"string","enum":["#
            + rungs
            + #"]},"reason":{"type":"string"}},"required":["complexity","reason"],"additionalProperties":false}"#
    }()

    /// How long an answer is worth waiting for.
    ///
    /// A cap on a call that never returns rather than a measurement of one that does. The namer
    /// measured the Claude Code invocation at eight to seventeen seconds and once at thirty eight,
    /// almost all of it thinking, so anything under half a minute would throw away good answers on
    /// a slow morning. What this guards against is a first message that never goes at all, and the
    /// card offers Skip long before it matters.
    public static let timeout = Duration.seconds(60)

    /// How much of the task the analyser is shown. The first few paragraphs say what the work is; a
    /// pasted log after them changes nothing but the bill.
    public static let taskLimit = 4_000

    private let ask: Ask
    /// `timeout`, unless the suite is driving a stream that never ends.
    private let waitLimit: Duration

    public init(ask: @escaping Ask = ModelRouter.live, timeout: Duration = ModelRouter.timeout) {
        self.ask = ask
        self.waitLimit = timeout
    }

    /// The production asker: the analyser's own agent, through its adapter.
    public static let live: Ask = { request in
        switch request.analyser.kind {
        case .claudeCode:
            return ClaudeRouterAsk.ask(request)
        case .codex:
            return CodexRouterAsk.ask(request)
        case .grok:
            return GrokRouterAsk.ask(request)
        case .cursor, .openCode:
            // `RouterAnalyser.resolve` never chooses these, since Bloom has no conversation with
            // either. Said as a failure rather than trusted, because this is the last door.
            return AsyncThrowingStream { $0.finish(throwing: ModelRouterError.unsupported(request.analyser.kind)) }
        }
    }

    /// The rendered prompt for one task.
    public static func prompt(
        task: String,
        project: String,
        template: String = PromptRegistry.definition(for: .routeTask).defaultTemplate
    ) -> String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = trimmed.count > taskLimit ? String(trimmed.prefix(taskLimit)) : trimmed

        return PromptTemplate.render(template, values: [
            PromptRegistry.RouteTask.task: capped,
            PromptRegistry.RouteTask.project: project,
        ]).text
    }

    /// Asks, and reports as it goes.
    ///
    /// Every element is the whole of what has been said so far, so a reader that drops one loses
    /// nothing. The last element is always finished, answered or failed, and the stream ends after
    /// it: there is no error path out of here, for the reason `WorkspaceNamer.suggest` has none.
    /// A workspace whose analyser could not be reached starts on what the window was set to, which
    /// is what it would have done with the router switched off.
    ///
    /// Cancelling the task that reads this stops the process. That is what Skip is.
    ///
    /// - Parameter executable: the agent's binary, when Settings names one of its own.
    public func progress(
        task: String,
        project: String,
        template: String,
        analyser: RouterAnalyser,
        executable: String? = nil
    ) -> AsyncStream<ModelRouterProgress> {
        let request = ModelRouterRequest(
            analyser: analyser,
            prompt: Self.prompt(task: task, project: project, template: template),
            executable: executable
        )
        let ask = self.ask
        let waitLimit = self.waitLimit
        // The task, not the rendered prompt: the built-in template is a page of instructions on
        // its own, so a blank task would still render to a full turn about nothing.
        let hasTask = !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return AsyncStream { continuation in
            let worker = Task {
                var progress = ModelRouterProgress()
                // A task with nothing in it asks nothing, rather than sending a blank turn.
                if hasTask {
                    do {
                        for try await signal in ask(request) {
                            let changed = progress.ingest(signal)
                            if progress.isFinished { break }
                            if changed { continuation.yield(progress) }
                        }
                    } catch {
                        // Not reported, on purpose: a CLI that is offline, signed out or killed
                        // by the deadline below is the same outcome for the caller, and `finish`
                        // is what says so.
                    }
                }
                progress.finish()
                continuation.yield(progress)
                continuation.finish()
            }
            // A cap on infinity, not a measurement. See `timeout`.
            let deadline = Task {
                do {
                    try await Task.sleep(for: waitLimit)
                    worker.cancel()
                } catch {
                    // Cancelled because the answer arrived first, which is the ordinary ending.
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
                deadline.cancel()
            }
        }
    }
}

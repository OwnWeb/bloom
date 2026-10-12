import Foundation

/// Asks a light model how much a task asks of the model that will do it, and is allowed to fail.
///
/// Prompt, deadline and reading are shared; each adapter (`ClaudeRouterAsk`, `CodexRouterAsk`,
/// `GrokRouterAsk`) only carries the question to its agent and turns the reply into
/// `RouterSignal`s. A light model, because a larger one classifies no better and costs more.
public struct ModelRouter: Sendable {
    /// Injected so the suite drives the whole path without a network, an account or a bill.
    public typealias Ask = @Sendable (ModelRouterRequest) -> AsyncThrowingStream<RouterSignal, Error>

    /// Names the JSON outright because only Claude Code can be made to answer through a schema.
    public static let systemPrompt = """
    You triage coding tasks for an app that chooses which model will do them. Do not use any \
    tool and do not read any file. Think briefly, then answer with only the JSON object the task \
    asks for, with no commentary before or after it.
    """

    /// Built from `TaskComplexity` so the rungs the model may name and the table's can never disagree.
    public static let jsonSchema: String = {
        let rungs = TaskComplexity.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"complexity":{"type":"string","enum":["#
            + rungs
            + #"]},"reason":{"type":"string"}},"required":["complexity","reason"],"additionalProperties":false}"#
    }()

    /// A cap on a call that never returns, not a measurement: the Claude call has taken up to 38
    /// seconds, almost all of it thinking.
    public static let timeout = Duration.seconds(60)

    /// The first paragraphs say what the work is; a pasted log after them only adds to the bill.
    public static let taskLimit = 4_000

    private let ask: Ask
    private let waitLimit: Duration

    public init(ask: @escaping Ask = ModelRouter.live, timeout: Duration = ModelRouter.timeout) {
        self.ask = ask
        self.waitLimit = timeout
    }

    public static let live: Ask = { request in
        switch request.analyser.kind {
        case .claudeCode:
            return ClaudeRouterAsk.ask(request)
        case .codex:
            return CodexRouterAsk.ask(request)
        case .grok:
            return GrokRouterAsk.ask(request)
        case .cursor, .openCode:
            // `RouterAnalyser.resolve` never chooses these; failed rather than trusted, as the last door.
            return AsyncThrowingStream { $0.finish(throwing: ModelRouterError.unsupported(request.analyser.kind)) }
        }
    }

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

    /// Every element is the whole of what has been said so far. The last is always finished and there
    /// is no error path: a workspace whose analyser failed starts on what the window was set to.
    /// Cancelling the reading task stops the process, which is what Skip is.
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
        // The task, not the rendered prompt: the template alone would still render a full turn.
        let hasTask = !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return AsyncStream { continuation in
            let worker = Task {
                var progress = ModelRouterProgress()
                if hasTask {
                    do {
                        for try await signal in ask(request) {
                            let changed = progress.ingest(signal)
                            if progress.isFinished { break }
                            if changed { continuation.yield(progress) }
                        }
                    } catch {
                    // Offline, signed out or past the deadline all end the same way, in `finish`.
                    }
                }
                progress.finish()
                continuation.yield(progress)
                continuation.finish()
            }
            let deadline = Task {
                do {
                    try await Task.sleep(for: waitLimit)
                    worker.cancel()
                } catch {
                // Cancelled because the answer arrived first.
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
                deadline.cancel()
            }
        }
    }
}

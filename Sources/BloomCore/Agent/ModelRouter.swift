import Foundation

/// Everything needed to ask the router, as a value, so the invocation can be asserted on without
/// a process ever existing. The same shape, and the same reason, as `WorkspaceNamerLaunch`.
public struct ModelRouterLaunch: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]
    /// The rendered prompt, written to stdin so a task that begins with a dash is never a flag.
    public let stdin: String
    public let cwd: String

    public init(executable: String, arguments: [String], stdin: String, cwd: String) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.cwd = cwd
    }
}

/// Asks Claude Haiku how much a task asks of the model that will do it, and is allowed to fail.
///
/// ## Why a separate `claude -p`, and why Haiku
///
/// Everything `WorkspaceNamer` says about this holds here, and the invocation is the namer's,
/// trimmed the same way: no tools, no MCP servers, no project settings, no session written to
/// `/resume`, Claude Code's system prompt replaced, and a scratch directory with no repository in
/// it, so the router sees the sentence somebody typed and nothing of their code. Bloom never holds
/// a credential: the CLI signs in, as it does for every other turn the app runs.
///
/// Haiku because the question is a reading of one paragraph, and the answer is worth having only
/// if it arrives before the person who asked has given up on it. A larger model would classify no
/// better and would put its own cost on every workspace, including the trivial ones the router
/// exists to make cheaper.
///
/// ## Why stream-json rather than the namer's single JSON object
///
/// Because the opening message waits for this answer, and a wait somebody can watch is a
/// different thing from a wait behind a spinner. With `--include-partial-messages` the model's
/// thinking arrives as it is written, and the card over the new conversation draws it under its
/// spinner. `ModelRouterProgress` folds the lines together; the answer is still the structured
/// output `--json-schema` forces, read off the `result` line exactly as the namer reads it.
public struct ModelRouter: Sendable {
    /// Runs a launch and hands back its stdout one line at a time. Injected so the suite drives the
    /// whole path without a network, an account or a bill.
    public typealias Run = @Sendable (ModelRouterLaunch) -> AsyncThrowingStream<String, Error>

    public static let executable = "claude"

    /// Fixed, not a setting, for the reason `WorkspaceNamer.model` is: tying it to the model picker
    /// would have somebody on Opus paying for Opus to decide that a typo is a typo.
    public static let model = "haiku"

    /// Replaces the CLI's own system prompt outright. Short on purpose: the rungs and what they
    /// mean are in the editable prompt, and this only has to establish the shape of the reply.
    public static let systemPrompt = """
    You triage coding tasks for an app that chooses which model will do them. Think briefly, \
    then answer through the structured output, with no commentary before or after it.
    """

    /// Forces the shape of the answer, built from `TaskComplexity` so the rungs the model may name
    /// and the rungs the table has can never disagree.
    public static let jsonSchema: String = {
        let rungs = TaskComplexity.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"complexity":{"type":"string","enum":["#
            + rungs
            + #"]},"reason":{"type":"string"}},"required":["complexity","reason"],"additionalProperties":false}"#
    }()

    /// How long an answer is worth waiting for.
    ///
    /// A cap on a call that never returns rather than a measurement of one that does. The namer
    /// measured the same invocation at eight to seventeen seconds and once at thirty eight, almost
    /// all of it thinking, so anything under half a minute would throw away good answers on a slow
    /// morning. What this guards against is a first message that never goes at all, and the card
    /// offers Skip long before it matters.
    public static let timeout = Duration.seconds(60)

    /// How much of the task the router is shown. The first few paragraphs say what the work is; a
    /// pasted log after them changes nothing but the bill.
    public static let taskLimit = 4_000

    private let run: Run
    /// `timeout`, unless the suite is driving a stream that never ends.
    private let waitLimit: Duration

    public init(run: @escaping Run = ModelRouter.shell, timeout: Duration = ModelRouter.timeout) {
        self.run = run
        self.waitLimit = timeout
    }

    /// The production runner: the CLI as a streaming process, its stdout as lines.
    ///
    /// Cancelling whatever reads the stream reaches the process, through the termination handler
    /// `StreamingProcess.lines` installs, so a skipped or abandoned route does not leave a `claude`
    /// thinking in the background for nobody.
    public static let shell: Run = { launch in
        AsyncThrowingStream { continuation in
            let reader = Task {
                let process = StreamingProcess(
                    executable: launch.executable,
                    arguments: launch.arguments,
                    cwd: launch.cwd,
                    mergeStderr: false
                )
                do {
                    // Touching `lines` is what starts the process, so it comes before the write.
                    let lines = process.lines
                    process.write(launch.stdin)
                    process.closeStdin()
                    for try await line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// Whether there is anything to ask. Checked before the card is ever drawn, so a machine with
    /// no `claude` on it starts its first turn straight away.
    public static var isAvailable: Bool {
        Shell.which(executable) != nil
    }

    public static func argv(model: String = ModelRouter.model) -> [String] {
        [
            "-p",
            "--model", ModelAlias.cliValue(for: model),
            // The fewest thinking tokens that still think out loud, which is both the latency and
            // the reasoning the card draws. Sorting a task onto one of five rungs does not reward
            // deliberation.
            "--effort", "low",
            "--output-format", "stream-json",
            // Required by the CLI with `-p` and stream-json. See docs/PROTOCOL.md.
            "--verbose",
            // The thinking as it is written rather than after it is finished, which is the whole
            // reason this is a stream.
            "--include-partial-messages",
            "--json-schema", jsonSchema,
            "--system-prompt", systemPrompt,
            // Empty string is "no tools at all", which is what guarantees the router cannot read
            // a file or run a command whatever the task text asks for.
            "--tools", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--safe-mode",
        ]
    }

    /// A directory with nothing in it. See `AgentScratchDirectory`.
    public static var scratchDirectory: String { AgentScratchDirectory.current() }

    public static func launch(prompt: String, model: String = ModelRouter.model) -> ModelRouterLaunch {
        ModelRouterLaunch(
            executable: executable,
            arguments: argv(model: model),
            stdin: prompt,
            cwd: scratchDirectory
        )
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
    /// A workspace whose router could not be reached starts on the model it was created with,
    /// which is what it would have done with the router switched off.
    ///
    /// Cancelling the task that reads this stops the process. That is what Skip is.
    public func progress(task: String, project: String, template: String) -> AsyncStream<ModelRouterProgress> {
        let rendered = Self.prompt(task: task, project: project, template: template)
        let run = self.run
        let waitLimit = self.waitLimit

        return AsyncStream { continuation in
            let worker = Task {
                var progress = ModelRouterProgress()
                // A task with nothing in it asks nothing, rather than sending a blank turn.
                if !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        for try await line in run(Self.launch(prompt: rendered)) {
                            let changed = progress.ingest(line: line)
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

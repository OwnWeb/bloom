import Foundation

/// Everything needed to run the Claude Code analyser, as a value, so the invocation can be asserted
/// on without a process ever existing. The same shape, and the same reason, as `WorkspaceNamerLaunch`.
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

/// The routing question asked of Claude Code: a `claude -p` with every tool off, read as
/// stream-json.
///
/// ## Why a separate `claude -p`
///
/// Everything `WorkspaceNamer` says about this holds here, and the invocation is the namer's,
/// trimmed the same way: no tools, no MCP servers, no project settings, no session written to
/// `/resume`, Claude Code's system prompt replaced, and a scratch directory with no repository in
/// it, so the analyser sees the sentence somebody typed and nothing of their code. Bloom never
/// holds a credential: the CLI signs in, as it does for every other turn the app runs. Of the three
/// agents this is the only one that can be asked with no tools at all; see `CodexRouterAsk` and
/// `GrokRouterAsk` for what the other two can and cannot promise.
///
/// ## Why stream-json rather than the namer's single JSON object
///
/// Because the opening message waits for this answer, and a wait somebody can watch is a different
/// thing from a wait behind a spinner. With `--include-partial-messages` the model's thinking
/// arrives as it is written, and the card over the new conversation draws it under its spinner.
/// The answer is still the structured output `--json-schema` forces, read off the `result` line
/// exactly as the namer reads it.
public enum ClaudeRouterAsk {
    /// Runs a launch and hands back its stdout one line at a time. Injected so the suite drives the
    /// whole path without a network, an account or a bill.
    public typealias Run = @Sendable (ModelRouterLaunch) -> AsyncThrowingStream<String, Error>

    /// The tool `--json-schema` answers through, as the CLI names it.
    static let structuredOutputTool = "StructuredOutput"

    public static func argv(model: String, effort: String, systemPrompt: String = ModelRouter.systemPrompt) -> [String] {
        var arguments = [
            "-p",
            "--model", ModelAlias.cliValue(for: model),
        ]
        // The fewest thinking tokens that still think out loud, which is both the latency and the
        // reasoning the card draws. Absent for a model that takes no level at all.
        if !effort.isEmpty { arguments += ["--effort", effort] }
        arguments += [
            "--output-format", "stream-json",
            // Required by the CLI with `-p` and stream-json. See docs/PROTOCOL.md.
            "--verbose",
            // The thinking as it is written rather than after it is finished, which is the whole
            // reason this is a stream.
            "--include-partial-messages",
            "--json-schema", ModelRouter.jsonSchema,
            "--system-prompt", systemPrompt,
            // Empty string is "no tools at all", which is what guarantees the analyser cannot read
            // a file or run a command whatever the task text asks for.
            "--tools", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--safe-mode",
        ]
        return arguments
    }

    public static func launch(_ request: ModelRouterRequest) -> ModelRouterLaunch {
        ModelRouterLaunch(
            executable: request.executable,
            arguments: argv(
                model: request.analyser.model.isEmpty ? RouterAnalyser.suggestedModel(for: .claudeCode, models: []) : request.analyser.model,
                effort: request.analyser.effort,
                systemPrompt: request.systemPrompt
            ),
            stdin: request.prompt,
            cwd: request.cwd
        )
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

    /// The question, asked, as signals.
    public static func ask(_ request: ModelRouterRequest, run: @escaping Run = ClaudeRouterAsk.shell) -> AsyncThrowingStream<RouterSignal, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                var decoder = Decoder()
                do {
                    for try await line in run(ClaudeRouterAsk.launch(request)) {
                        for signal in decoder.signals(for: line) { continuation.yield(signal) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// stream-json in, signals out, one line at a time.
    ///
    /// Stateful for one reason: with `--include-partial-messages` every thinking block arrives
    /// twice, once in pieces and once whole in its `assistant` event, and passing both on would
    /// print the reasoning twice. The whole block is used only when no piece of one ever arrived.
    struct Decoder {
        private var streamedThinking = false
        private var hasThinking = false

        mutating func signals(for line: String) -> [RouterSignal] {
            guard let json = JSONValue.parse(line) else { return [] }
            switch json["type"]?.stringValue {
            case "stream_event": return signals(event: json["event"])
            case "assistant": return signals(assistant: json["message"])
            case "result": return signals(result: json)
            // `system` lines, hooks and anything added later say nothing about the answer.
            default: return []
            }
        }

        private mutating func signals(event: JSONValue?) -> [RouterSignal] {
            guard let event else { return [] }
            switch event["type"]?.stringValue {
            case "content_block_start":
                // A second block of thinking reads as a new paragraph rather than running on from
                // the last word of the first.
                guard event["content_block"]?["type"]?.stringValue == "thinking", hasThinking else { return [] }
                return [.thinking("\n\n")]
            case "content_block_delta":
                guard event["delta"]?["type"]?.stringValue == "thinking_delta",
                      let text = event["delta"]?["thinking"]?.stringValue, !text.isEmpty
                else { return [] }
                streamedThinking = true
                hasThinking = true
                return [.thinking(text)]
            default:
                return []
            }
        }

        private mutating func signals(assistant message: JSONValue?) -> [RouterSignal] {
            var out: [RouterSignal] = []
            for block in message?["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "thinking":
                    guard !streamedThinking, let text = block["thinking"]?.stringValue, !text.isEmpty else { continue }
                    out.append(.thinking((hasThinking ? "\n\n" : "") + text))
                    hasThinking = true
                case "tool_use":
                    // How `--json-schema` delivers its answer inside the turn.
                    if block["name"]?.stringValue == ClaudeRouterAsk.structuredOutputTool, let input = block["input"] {
                        out.append(.structured(input))
                    }
                case "text":
                    if let text = block["text"]?.stringValue, !text.isEmpty { out.append(.text(text)) }
                default:
                    continue
                }
            }
            return out
        }

        /// The last line of the turn. The result's own `structured_output` is where `WorkspaceNamer`
        /// measured the answer; the `result` text is the fallback for a CLI that puts it there.
        private func signals(result: JSONValue) -> [RouterSignal] {
            if result["is_error"]?.boolValue == true { return [.finished(isError: true)] }
            var out: [RouterSignal] = []
            if let structured = result["structured_output"] {
                out.append(.structured(structured))
            } else if let object = ModelRouterProgress.object(in: result["result"]?.stringValue) {
                out.append(.structured(object))
            }
            out.append(.finished(isError: false))
            return out
        }
    }
}

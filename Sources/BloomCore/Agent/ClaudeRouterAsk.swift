import Foundation

/// The Claude Code analyser's invocation as a value, so it can be asserted on without a process.
public struct ModelRouterLaunch: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]
    /// Written to stdin so a task that begins with a dash is never a flag.
    public let stdin: String
    public let cwd: String

    public init(executable: String, arguments: [String], stdin: String, cwd: String) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.cwd = cwd
    }
}

/// The routing question asked of Claude Code: the namer's `claude -p` invocation, with no tools,
/// MCP servers, project settings or session, in a scratch directory, so the analyser sees only the
/// sentence typed. Stream-json with partial messages, so the card can show the thinking while the
/// opening message waits; the answer is still the `--json-schema` structured output.
public enum ClaudeRouterAsk {
    /// Injected so the suite drives the whole path without a network, an account or a bill.
    public typealias Run = @Sendable (ModelRouterLaunch) -> AsyncThrowingStream<String, Error>

    static let structuredOutputTool = "StructuredOutput"

    public static func argv(model: String, effort: String, systemPrompt: String = ModelRouter.systemPrompt) -> [String] {
        var arguments = [
            "-p",
            "--model", ModelAlias.cliValue(for: model),
        ]
        // See `RouterAnalyser.readingEffort`. Absent for a model that takes none.
        if !effort.isEmpty { arguments += ["--effort", effort] }
        arguments += [
            "--output-format", "stream-json",
            // Required by the CLI with `-p` and stream-json. See docs/PROTOCOL.md.
            "--verbose",
            "--include-partial-messages",
            "--json-schema", ModelRouter.jsonSchema,
            "--system-prompt", systemPrompt,
            // Empty is "no tools at all", so the analyser cannot read a file whatever the task asks.
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

    /// Cancelling the reader reaches the process through `StreamingProcess.lines`, so a skipped route
    /// leaves no `claude` thinking in the background.
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

    /// Stateful because with `--include-partial-messages` every thinking block arrives twice (in
    /// pieces, then whole); the whole block is used only when no piece arrived.
    struct Decoder {
        private var streamedThinking = false
        private var hasThinking = false

        mutating func signals(for line: String) -> [RouterSignal] {
            guard let json = JSONValue.parse(line) else { return [] }
            switch json["type"]?.stringValue {
            case "stream_event": return signals(event: json["event"])
            case "assistant": return signals(assistant: json["message"])
            case "result": return signals(result: json)
            default: return []
            }
        }

        private mutating func signals(event: JSONValue?) -> [RouterSignal] {
            guard let event else { return [] }
            switch event["type"]?.stringValue {
            case "content_block_start":
                // A second block of thinking starts a new paragraph.
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

        /// `structured_output` first; the `result` text is the fallback for a CLI that puts it there.
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

import Foundation

/// What the router has said so far, folded together from the CLI's stream-json one line at a time.
///
/// A value rather than a callback per event, because the card that draws it wants the whole of
/// the reasoning on every frame and nothing about how it arrived, and because a value can be
/// handed across an actor boundary and compared. Every line goes through `ingest`, so the suite
/// can replay a recorded stream and look at exactly what the card would have shown.
public struct ModelRouterProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case thinking
        case answered(ModelRouterAnswer)
        /// The process failed, timed out, was skipped, or answered with something unusable. One
        /// case for all of them, because the caller does the same thing whichever it was: the chat
        /// keeps the model it was created with.
        case failed
    }

    /// The model's thinking, as it streams. Empty when the model did not think out loud, which
    /// the card copes with by drawing only its spinner.
    public private(set) var reasoning = ""
    public private(set) var phase: Phase = .thinking

    /// Whether any thinking has arrived as deltas. With `--include-partial-messages` every
    /// thinking block arrives twice, once in pieces and once whole in its `assistant` event, and
    /// reading both would print the reasoning twice.
    private var streamedThinking = false
    /// The answer as the turn delivered it, before the `result` line confirms it. `--json-schema`
    /// is answered through a tool call, so this is the fallback for a result that carries no copy.
    private var structured: JSONValue?

    /// The tool `--json-schema` answers through, as the CLI names it.
    static let structuredOutputTool = "StructuredOutput"

    public init() {}

    public var answer: ModelRouterAnswer? {
        if case .answered(let answer) = phase { return answer }
        return nil
    }

    public var isFinished: Bool { phase != .thinking }

    /// Folds one line in, and says whether anything a reader can see has changed.
    ///
    /// Anything after the phase has left `.thinking` is ignored, so a line arriving after a
    /// timeout cannot turn a failure back into an answer the caller has stopped waiting for.
    @discardableResult
    public mutating func ingest(line: String) -> Bool {
        guard phase == .thinking, let json = JSONValue.parse(line) else { return false }
        switch json["type"]?.stringValue {
        case "stream_event": return ingest(event: json["event"])
        case "assistant": return ingest(assistant: json["message"])
        case "result": return ingest(result: json)
        // `system` lines, hooks and anything added later say nothing about the answer.
        default: return false
        }
    }

    /// The stream ended. Whatever has not been answered by now has failed.
    public mutating func finish() {
        if phase == .thinking { phase = .failed }
    }

    private mutating func ingest(event: JSONValue?) -> Bool {
        guard let event else { return false }
        switch event["type"]?.stringValue {
        case "content_block_start":
            // A second block of thinking reads as a new paragraph rather than running on from the
            // last word of the first.
            guard event["content_block"]?["type"]?.stringValue == "thinking", !reasoning.isEmpty else {
                return false
            }
            reasoning += "\n\n"
            return false
        case "content_block_delta":
            guard event["delta"]?["type"]?.stringValue == "thinking_delta",
                  let text = event["delta"]?["thinking"]?.stringValue, !text.isEmpty
            else { return false }
            streamedThinking = true
            reasoning += text
            return true
        default:
            return false
        }
    }

    private mutating func ingest(assistant message: JSONValue?) -> Bool {
        guard let blocks = message?["content"]?.arrayValue else { return false }
        var changed = false
        for block in blocks {
            switch block["type"]?.stringValue {
            case "thinking":
                guard !streamedThinking, let text = block["thinking"]?.stringValue, !text.isEmpty else {
                    continue
                }
                reasoning += (reasoning.isEmpty ? "" : "\n\n") + text
                changed = true
            case "tool_use":
                if block["name"]?.stringValue == Self.structuredOutputTool, let input = block["input"] {
                    structured = input
                }
            default:
                continue
            }
        }
        return changed
    }

    /// The last line of the turn, and the only one that settles anything.
    ///
    /// Three places the answer can be, in the order they are trusted: the result's own
    /// `structured_output`, which is where `WorkspaceNamer` measured it; the `result` text parsed
    /// as JSON, for a CLI that puts it there; and the tool call seen during the turn.
    private mutating func ingest(result: JSONValue) -> Bool {
        if result["is_error"]?.boolValue == true {
            phase = .failed
            return true
        }
        let candidates = [result["structured_output"], Self.object(in: result["result"]?.stringValue), structured]
        for candidate in candidates {
            if let candidate, let answer = ModelRouting.answer(from: candidate) {
                phase = .answered(answer)
                return true
            }
        }
        phase = .failed
        return true
    }

    /// A JSON object out of a text answer, forgiving the code fence a model wraps one in more often
    /// than it is asked to.
    static func object(in text: String?) -> JSONValue? {
        guard var body = text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            return nil
        }
        if body.hasPrefix("```") {
            body = body
                .split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst()
                .filter { !$0.hasPrefix("```") }
                .joined(separator: "\n")
        }
        guard let parsed = JSONValue.parse(body), parsed.objectValue != nil else { return nil }
        return parsed
    }
}

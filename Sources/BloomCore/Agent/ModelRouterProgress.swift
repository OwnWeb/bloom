import Foundation

/// What the analyser has said so far, folded together from its signals.
///
/// A value rather than a callback per event, because the card that draws it wants the whole of
/// the reasoning on every frame and nothing about how it arrived, and because a value can be
/// handed across an actor boundary and compared. It reads `RouterSignal`s rather than any one
/// agent's protocol, so the same rules settle an answer from Claude Code, Codex or Grok, and the
/// suite can replay any of them and look at exactly what the card would have shown.
public struct ModelRouterProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case thinking
        case answered(ModelRouterAnswer)
        /// The process failed, timed out, was skipped, or answered with something unusable. One
        /// case for all of them, because the caller does the same thing whichever it was: the chat
        /// keeps what the window was set to.
        case failed
    }

    /// The model's thinking, as it streams. Empty when the model did not think out loud, which
    /// the card copes with by drawing only its spinner.
    public private(set) var reasoning = ""
    public private(set) var phase: Phase = .thinking

    /// The answer as prose, for an agent that cannot be made to answer in a structure.
    private var answerText = ""
    /// The answer as a structure, which wins over the prose whenever both arrive.
    private var structured: JSONValue?

    public init() {}

    public var answer: ModelRouterAnswer? {
        if case .answered(let answer) = phase { return answer }
        return nil
    }

    public var isFinished: Bool { phase != .thinking }

    /// Folds one signal in, and says whether anything a reader can see has changed.
    ///
    /// Anything after the phase has left `.thinking` is ignored, so a signal arriving after a
    /// timeout cannot turn a failure back into an answer the caller has stopped waiting for.
    @discardableResult
    public mutating func ingest(_ signal: RouterSignal) -> Bool {
        guard phase == .thinking else { return false }
        switch signal {
        case .thinking(let text):
            guard !text.isEmpty else { return false }
            reasoning += text
            return true
        case .text(let text):
            answerText += text
            return false
        case .structured(let value):
            structured = value
            return false
        case .finished(let isError):
            phase = isError ? .failed : settled()
            return true
        }
    }

    /// The stream ended. Whatever has not been answered by now has failed.
    public mutating func finish() {
        if phase == .thinking { phase = .failed }
    }

    /// The answer, from the structure when there is one and from the prose otherwise.
    private func settled() -> Phase {
        for candidate in [structured, Self.object(in: answerText)] {
            if let candidate, let answer = ModelRouting.answer(from: candidate) {
                return .answered(answer)
            }
        }
        return .failed
    }

    /// A JSON object out of a text answer.
    ///
    /// Forgiving in the two ways models are, more often than they are asked to be: a code fence
    /// around the object, and a sentence before or after it. The outermost braces are what is
    /// parsed, so an answer that says "Here it is:" and then gives the object still counts.
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
        if let parsed = JSONValue.parse(body), parsed.objectValue != nil { return parsed }
        guard let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close else {
            return nil
        }
        guard let parsed = JSONValue.parse(String(body[open...close])), parsed.objectValue != nil else {
            return nil
        }
        return parsed
    }
}

import Foundation

/// What the analyser has said so far, folded from `RouterSignal`s. A value rather than a callback,
/// so it crosses actors, compares, and lets the suite replay exactly what the card would show.
public struct ModelRouterProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case thinking
        case answered(ModelRouterAnswer)
        /// Failed, timed out, skipped or unusable: the caller does the same thing for all of them.
        case failed
    }

    /// Empty when the model did not think out loud; the card then draws only its spinner.
    public private(set) var reasoning = ""
    public private(set) var phase: Phase = .thinking

    private var answerText = ""
    private var structured: JSONValue?

    public init() {}

    public var answer: ModelRouterAnswer? {
        if case .answered(let answer) = phase { return answer }
        return nil
    }

    public var isFinished: Bool { phase != .thinking }

    /// Ignored once the phase has left `.thinking`, so a signal after a timeout cannot revive it.
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

    public mutating func finish() {
        if phase == .thinking { phase = .failed }
    }

    private func settled() -> Phase {
        for candidate in [structured, Self.object(in: answerText)] {
            if let candidate, let answer = ModelRouting.answer(from: candidate) {
                return .answered(answer)
            }
        }
        return .failed
    }

    /// Forgives a code fence and a sentence around the object by parsing the outermost braces.
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

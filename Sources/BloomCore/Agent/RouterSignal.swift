import Foundation

/// One thing an analyser said. Each adapter translates its own protocol into these, so the
/// progress and the rules that read the answer are written once.
public enum RouterSignal: Sendable, Equatable {
    /// An adapter that sees a second block of thinking sends its paragraph break as one of these.
    case thinking(String)
    /// Where an agent with no structured output puts the JSON it was asked for.
    case text(String)
    /// Wins over anything in `text`.
    case structured(JSONValue)
    /// An error is the CLI's verdict on the turn, not on the answer.
    case finished(isError: Bool)
}

public struct ModelRouterRequest: Sendable, Hashable {
    public var analyser: RouterAnalyser
    /// Written to the agent as the user's turn, never as an argument, so a leading dash is no flag.
    public var prompt: String
    public var systemPrompt: String
    public var executable: String
    /// A directory with nothing in it. See `AgentScratchDirectory`.
    public var cwd: String

    public init(
        analyser: RouterAnalyser,
        prompt: String,
        systemPrompt: String = ModelRouter.systemPrompt,
        executable: String? = nil,
        cwd: String = AgentScratchDirectory.current()
    ) {
        self.analyser = analyser
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.executable = executable ?? analyser.kind.executableName
        self.cwd = cwd
    }
}

public enum ModelRouterError: Error, Sendable, Equatable {
    case unsupported(AgentKind)
}

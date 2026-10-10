import Foundation

/// One thing an analyser said, in the four words every agent's protocol can be translated into.
///
/// Claude Code speaks stream-json, Codex its app-server's JSON-RPC and Grok ACP, and the router
/// wants the same three things out of each: the thinking as it is written, the answer, and the
/// moment it is over. Each agent's adapter translates its own events into these, so the progress
/// the card draws and the rules that read the answer are written once. See `ClaudeRouterAsk`,
/// `CodexRouterAsk` and `GrokRouterAsk`.
public enum RouterSignal: Sendable, Equatable {
    /// A piece of the model's reasoning, to be appended to what has arrived so far. An adapter
    /// that sees a second block of thinking sends its paragraph break as one of these.
    case thinking(String)
    /// A piece of the answer as prose, which is where an agent with no structured output puts
    /// the JSON it was asked for.
    case text(String)
    /// The answer as a structure the CLI forced, which wins over anything in `text`.
    case structured(JSONValue)
    /// The turn is over. An error is the CLI's own verdict on the turn, not on the answer.
    case finished(isError: Bool)
}

/// Everything one routing call needs, whichever agent answers it.
public struct ModelRouterRequest: Sendable, Hashable {
    public var analyser: RouterAnalyser
    /// The rendered routing prompt. Written to the agent as the user's turn, never as an argument,
    /// so a task that begins with a dash is never a flag.
    public var prompt: String
    public var systemPrompt: String
    /// The agent's binary, the owner's own path when Settings names one. See
    /// `AgentCatalog.executable(for:override:)`.
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

/// Why a routing call could not even be asked.
public enum ModelRouterError: Error, Sendable, Equatable {
    /// Bloom has no way to hold a conversation with this agent, so it cannot ask it anything.
    case unsupported(AgentKind)
}

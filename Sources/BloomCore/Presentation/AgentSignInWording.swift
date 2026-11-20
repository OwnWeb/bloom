import Foundation

/// What the Agents pane calls signing an agent in, in that agent's own terms.
///
/// OpenCode has no account: `opencode auth login` connects a provider, and a stock install is
/// already connected through its hosted free models. "Sign in with another account" over it
/// promised something that does not exist, so it is named for what the command does.
public struct AgentSignInWording: Equatable, Sendable {
    public let button: String
    public let help: String
    public let title: String

    public init(kind: AgentKind, isConnected: Bool) {
        switch kind {
        case .openCode:
            button = isConnected ? "Connect another provider…" : "Connect a provider…"
            help = "Run opencode auth login to connect a provider to OpenCode."
            title = "Connect a provider to OpenCode"
        case .claudeCode, .codex, .grok, .cursor:
            button = isConnected ? "Sign in with another account…" : "Sign in…"
            help = "Sign in to \(kind.label) in Bloom."
            title = "Sign in to \(kind.label)"
        }
    }
}

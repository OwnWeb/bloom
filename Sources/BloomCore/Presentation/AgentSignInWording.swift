import Foundation

/// What the Agents pane and its sign-in sheet call signing an agent in, in that agent's terms.
///
/// OpenCode has no account: `opencode auth login` connects a provider, and a stock install is
/// already connected through its hosted free models. "Sign in with another account", and the
/// sheet's "This changes the account used by OpenCode", promised something that does not exist,
/// so every sentence is named for what the command does.
public struct AgentSignInWording: Equatable, Sendable {
    public let kind: AgentKind
    /// Whether the agent already counts as connected, which only the pane's button reads.
    public let isConnected: Bool

    public init(kind: AgentKind, isConnected: Bool = false) {
        self.kind = kind
        self.isConnected = isConnected
    }

    private var connectsAProvider: Bool { kind == .openCode }

    public var button: String {
        switch (connectsAProvider, isConnected) {
        case (true, true): "Connect another provider…"
        case (true, false): "Connect a provider…"
        case (false, true): "Sign in with another account…"
        case (false, false): "Sign in…"
        }
    }

    public var help: String {
        connectsAProvider ? "Run opencode auth login to connect a provider to OpenCode."
            : "Sign in to \(kind.label) in Bloom."
    }

    public var title: String {
        connectsAProvider ? "Connect a provider to OpenCode" : "Sign in to \(kind.label)"
    }

    public var intro: String {
        connectsAProvider
            ? "Follow the prompts below to connect a provider. If a browser opens, finish there."
            : "Follow the prompts below to sign in. If a browser opens, finish signing in there."
    }

    /// Said when the agent is already connected. OpenCode adds a provider beside the ones it has
    /// rather than replacing an account, so it has nothing to warn about.
    public var switchingNote: String? {
        connectsAProvider ? nil : "This changes the account used by \(kind.label) on this Mac."
    }

    public var finished: String {
        connectsAProvider ? "Provider command finished." : "Sign-in command finished."
    }

    public var copyCommand: String {
        connectsAProvider ? "Copy provider command" : "Copy sign-in command"
    }

    public var copyHelp: String {
        connectsAProvider ? "Run this command in your own terminal to connect a provider."
            : "Run this command in your own terminal to sign in."
    }

    public var unfinished: String {
        connectsAProvider
            ? "Connecting a provider did not finish. Check the terminal above, then try again."
            : "Sign-in did not finish. Check the terminal above, then try again."
    }
}

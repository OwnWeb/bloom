import Foundation

/// The process-environment boundary around Bloom-managed local model-gateway credentials.
///
/// Agent execution is the only path that may receive one, and it receives only the canonical
/// variable for the selected agent. Terminals, repository scripts, services and their descendants
/// cross `untrustedProcess` instead. Its default is removal, so an environment assembled from an
/// unknown source cannot accidentally become an agent environment.
///
/// The switches over every `AgentKind` are deliberate. Adding an agent does not compile until its
/// credential names and canonical agent-only variable have an explicit policy decision here.
public enum ProviderCredentialEnvironment {
    /// Removes current provider variables and their common aliases, case-insensitively. Values are
    /// never inspected, rendered or included in an error.
    public static func untrustedProcess(_ environment: [String: String]) -> [String: String] {
        environment.filter { !blockedNames.contains($0.key.uppercased()) }
    }

    /// Overlays a Runner-authorised local gateway environment without retaining provider
    /// credentials inherited by the Runner itself. Only the selected agent's local credential
    /// from `granted` may cross this boundary.
    public static func agent(
        _ agent: AgentKind, granted: [String: String], inheriting inherited: [String: String]
    ) -> [String: String] {
        var environment = untrustedProcess(inherited)
        environment.merge(untrustedProcess(granted)) { _, granted in granted }
        if let key = granted[canonicalName(for: agent)] {
            environment[canonicalName(for: agent)] = key
        }
        return environment
    }

    public static var prohibitedNames: Set<String> { blockedNames }

    private static let blockedNames = Set(AgentKind.allCases.flatMap(aliases(for:)))

    private static func canonicalName(for agent: AgentKind) -> String {
        switch agent {
        case .claudeCode, .cursor, .openCode: "ANTHROPIC_API_KEY"
        case .codex: "OPENAI_API_KEY"
        case .grok: "XAI_API_KEY"
        }
    }

    private static func aliases(for agent: AgentKind) -> [String] {
        switch agent {
        case .claudeCode:
            ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY", "CLAUDE_CODE_API_KEY",
             "CLAUDE_CODE_OAUTH_TOKEN"]
        case .codex:
            ["OPENAI_API_KEY", "OPENAI_API_TOKEN", "OPENAI_KEY", "CODEX_API_KEY"]
        case .grok:
            ["XAI_API_KEY", "XAI_API_TOKEN", "GROK_API_KEY"]
        case .cursor:
            ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY", "CURSOR_API_KEY"]
        case .openCode:
            ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY", "OPENCODE_API_KEY"]
        }
    }
}

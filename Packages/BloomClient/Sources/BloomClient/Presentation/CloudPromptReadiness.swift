import Foundation

/// What is missing before a prompt in a Cloud workspace can start a turn, said before somebody
/// types rather than after runbloom.app refuses the turn.
///
/// **Two of the three refusals are knowable in advance**, because `/api/v1/me` says whether GitHub
/// is connected and which agent keys resolve. The third, push access to the repository, is only
/// known when runbloom.app checks it, so it is shown as its refusal arrives, in runbloom.app's own
/// words, with the same way forward. See `CloudRefusalNotice`.
public struct CloudPromptReadiness: Sendable, Hashable {
    public var sentence: String
    /// Whether to offer the way to runbloom.app, which is where all of this is settled.
    public var opensRunbloom: Bool

    /// Nil when this person can prompt in this chat as far as the account says.
    ///
    /// - Parameters:
    ///   - agent: the chat's agent, by its wire name (`claude`, `codex`).
    public init?(account: RunbloomAccount?, teamID: String, agent: String) {
        guard let account else { return nil }
        if !account.githubConnected {
            sentence = "Connect GitHub on runbloom.app before prompting here. A Bloom Cloud workspace commits and pushes as you."
            opensRunbloom = true
            return
        }
        // Said only when runbloom.app listed keys at all: an older one sends an empty list, which is
        // not the same as every key being missing.
        guard !account.agentKeys.isEmpty, !account.hasAgentKey(team: teamID, agent: agent) else { return nil }
        let name = agent == "codex" ? "Codex" : "Claude Code"
        sentence = "This team has no \(name) API key yet, so a turn here cannot start. Add one on runbloom.app, or open a chat with another agent."
        opensRunbloom = true
    }
}

/// A refusal from a machine or from runbloom.app, said in its own words with a way forward.
///
/// **runbloom.app's sentence is shown as it wrote it.** It knows why it refused and the app does
/// not, so nothing here rewrites it; what the app adds is the button back to the page where the
/// thing it is complaining about is settled, which is what a bare refusal was missing.
public struct CloudRefusalNotice: Sendable, Hashable {
    public var sentence: String
    public var opensRunbloom: Bool

    public init(message: String, code: String?) {
        sentence = message.trimmingCharacters(in: .whitespacesAndNewlines)
        opensRunbloom = Self.settledOnRunbloom.contains(code ?? "")
    }

    public init(refusal: RunbloomRefusal) {
        self.init(message: refusal.message, code: refusal.code)
    }

    /// The codes whose cause is a setting on runbloom.app rather than anything on this Mac or in
    /// the workspace.
    ///
    /// `no_github_connection` is the same refusal under the name it shipped with by accident;
    /// runbloom.app answers `github_not_connected` now, and both are here until the copies in the
    /// wild have caught up.
    static let settledOnRunbloom: Set<String> = [
        "no_agent_key", "github_not_connected", "no_github_connection", "no_push_access", "not_a_collaborator", "no_team_agent_key",
        "limit_reached", "repository_not_allowed", "forbidden",
    ]
}

import Foundation

/// Who an agent's commits are by, on a machine.
///
/// **Without this no agent on a Cloud workspace could commit.** The agent runs as the machine's
/// agent user, which has no `user.name` or `user.email` anywhere, so `git commit` stopped at
/// "Author identity unknown" and the agent, reasonably, tried `git config user.name`, which the
/// git wrapper refused as well. The identity goes in as `GIT_AUTHOR_*` and `GIT_COMMITTER_*`
/// rather than into a config file, because it belongs to a turn: the machine is shared, and a
/// file written for one person's turn would sign the next person's commits.
///
/// **It is Bloom's, not the prompter's, because the machine is not told who the prompter is.**
/// runbloom.app's turn start carries model grants, the person's own environment and a GitHub
/// grant, and neither of the grants names anybody. So the default is a name that is honest about
/// where the commit came from, and a person who wants their own sets `GIT_AUTHOR_NAME` and the
/// rest in their personal environment on runbloom.app, which arrives in the same environment and
/// wins over this.
enum AgentGitIdentity {
    static let name = "Bloom"
    static let email = "bloom@runbloom.app"

    /// `environment` with the four identity variables filled in wherever it does not already
    /// have them. An empty value counts as absent, since git refuses an empty name too.
    static func filling(_ environment: [String: String]) -> [String: String] {
        var filled = environment
        let defaults = [
            "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
            "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email,
        ]
        for (key, value) in defaults where (filled[key] ?? "").isEmpty {
            filled[key] = value
        }
        return filled
    }
}

import Foundation

/// How a team limit reads in the app, from runbloom.app's refusal.
///
/// The sentence is runbloom.app's, shown as it wrote it. What this adds is the one distinction the
/// design asks for: `concurrent_machines` clears by itself when another Cloud workspace in the team
/// goes to sleep, so it reads as waiting, and the prompt behind it as queued; every other limit
/// needs a person or a new month, so it reads as blocked. See "Limits" in docs/REMOTE-WORKSPACES.md.
public struct LimitNotice: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Carries on by itself.
        case waiting
        /// Needs somebody to act.
        case blocked
    }

    public var kind: Kind
    public var limit: String
    public var message: String
    /// What follows runbloom.app's sentence, in the app's own words.
    public var detail: String

    public init(limit: String, message: String) {
        self.limit = limit
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch limit {
        case "concurrent_machines":
            kind = .waiting
            detail = "This carries on by itself once another Bloom Cloud workspace in your team goes to sleep."
        case "monthly_usage":
            kind = .blocked
            detail = "A team owner can raise the monthly limit on runbloom.app, or it resets next month."
        case "total_machines":
            kind = .blocked
            detail = "Archive a Bloom Cloud workspace your team no longer needs, or ask a team owner to raise the limit."
        case "kill_switch":
            kind = .blocked
            detail = "Bloom Cloud workspaces are paused for everyone right now. They come back without anything to do on your side."
        default:
            kind = .blocked
            detail = "Ask a team owner to look at the team's limits on runbloom.app."
        }
        self.message = trimmed.isEmpty ? Self.fallback(limit) : trimmed
    }

    public init?(refusal: RunbloomRefusal) {
        guard refusal.isLimit else { return nil }
        self.init(limit: refusal.limit ?? "", message: refusal.message)
    }

    private static func fallback(_ limit: String) -> String {
        limit == "concurrent_machines" ? "Your team has as many Bloom Cloud workspaces awake as it can." : "Your team reached a Bloom Cloud workspace limit."
    }
}

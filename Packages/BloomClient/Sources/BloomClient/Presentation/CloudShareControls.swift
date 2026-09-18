import Foundation

/// What the Share popover may let somebody do, and how long a link it shows has left.
///
/// **Refused after pressing is not the same as saying so.** runbloom.app lets only a workspace's
/// owner change who it is shared with, and the popover drew every control live for everybody: a
/// collaborator could flip the team switch, remove a person or create a link, and what came back
/// was a red sentence at the foot of the popover saying no. The controls are the place to say it,
/// so they are dimmed and the reason is written once, above them.
///
/// Here rather than in the popover because who may do what is a rule, and a rule taken inside a
/// `View` is a rule nothing can test. See `CloudSharePopover`.
public enum CloudShareControls {
    /// The role runbloom.app gives the signed-in account for this workspace: `owner`,
    /// `collaborator`, or nil for a team owner or admin who can see that it exists without being
    /// in it. Only the first may change any of this.
    public static func canChange(role: String?) -> Bool { role == "owner" }

    /// Said once, above the two cards, rather than on each control that is dimmed.
    public static let othersCannotChange =
        "Only the owner of this Bloom Cloud workspace can change who it is shared with."

    /// How long a preview link has left, as a phrase to draw beside it.
    ///
    /// A link lasts an hour, which the caption already says; what a reader wants from a link that
    /// exists is how much of that hour is left, because the difference between fifty minutes and
    /// two decides whether it is worth sending. Nil where runbloom.app sent no expiry, so nothing
    /// is drawn rather than something guessed.
    public static func expiry(of share: PreviewShare, now: Date = Date()) -> String? {
        guard let expires = share.expiresAt else { return nil }
        let seconds = expires.timeIntervalSince(now)
        if seconds <= 0 { return "Expired" }
        if seconds < 60 { return "Expires in under a minute" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Expires in \(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = Int((seconds / 3600).rounded())
        return "Expires in \(hours) hour\(hours == 1 ? "" : "s")"
    }
}

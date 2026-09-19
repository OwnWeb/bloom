import Foundation

/// What the sidebar shows of Bloom Cloud: nothing, the small card inviting a sign in, or the list.
///
/// **Signed out, a card rather than a section.** It was the section heading, the same title again,
/// a sentence cut off at the sidebar's width and a link, which the owner found plain and
/// repetitive. It is one card now, with no heading of its own, one line that fits and a Sign In
/// button, and it can be dismissed for good by somebody not using Bloom Cloud.
///
/// **Dismissing hides the whole of Bloom Cloud in the sidebar**, kept as a preference that
/// Settings, under Bloom Cloud, turns back on. Signing in turns it back on as well, because
/// somebody who has just signed in is using it.
///
/// **A Mac that has never signed in shows nothing**, as before: see `hasEverSignedIn` on the app's
/// `CloudWorkspaces`. The card is the way back into an account, not an advertisement.
public enum CloudSidebarPresence: Sendable, Equatable {
    case hidden
    case signInCard
    case list

    public static func decide(isSignedIn: Bool, hasEverSignedIn: Bool, isShown: Bool) -> CloudSidebarPresence {
        guard isShown else { return .hidden }
        if isSignedIn { return .list }
        return hasEverSignedIn ? .signInCard : .hidden
    }

    /// Whether the sidebar shows Bloom Cloud at all, from what the defaults hold under `settingKey`.
    /// Absent means shown.
    public static func isShown(stored: Any?) -> Bool {
        (stored as? Bool) ?? true
    }

    public static let settingKey = "sidebar.showsBloomCloud"
    public static let settingTitle = "Show Bloom Cloud in the sidebar"

    /// The card's one line. Short enough to sit on two lines at the sidebar's narrowest.
    public static let cardLine = "Run agents on their own machine, even while your Mac sleeps."

    /// The dismiss button's tooltip, which says where it comes back from.
    public static let dismissHelp = "Hide Bloom Cloud from the sidebar. Bring it back in Settings, under Bloom Cloud."
}

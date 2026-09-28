import Foundation

/// One closed chat, as the menu offering to reopen it draws it.
///
/// Flat fields rather than the `Session` row they were read from, because a menu row wants four
/// facts and that row carries twenty-four. The message count is the one that is not on the row at
/// all: it is `COUNT(*)` over `messages`, and it is here because it is the fact that separates a
/// scratch tab somebody opened by mistake from a day of work.
public struct ClosedChat: Sendable, Hashable, Identifiable {
    public let id: SessionID
    public let title: String
    public let agentKind: AgentKind
    public let messageCount: Int
    /// When it was closed. Never optional, for `ArchivedWorkspaceFootprint.archivedAt`'s reason:
    /// a list ordered by age cannot have a hole in it, and `Store` only builds one of these from
    /// a row whose `archived_at` is set.
    public let closedAt: Date

    public init(
        id: SessionID,
        title: String,
        agentKind: AgentKind,
        messageCount: Int,
        closedAt: Date
    ) {
        self.id = id
        self.title = title
        self.agentKind = agentKind
        self.messageCount = messageCount
        self.closedAt = closedAt
    }
}

/// Which closed chats a workspace offers back, and how each one reads.
///
/// The other half of `SessionClosure`, whose own doc comment wrote the hole down before anything
/// filled it: a closed conversation is archived rather than deleted, "but nothing in the app
/// clears `archivedAt` on a session and nothing lists archived ones, so from where the user is
/// standing it does not come back". It did not come back. The owner closed a chat holding 13,872
/// messages, every one of them still in the database, and the only way to see any of it again was
/// `UPDATE sessions SET archived_at = NULL` typed into sqlite3 by hand.
///
/// An archived workspace has had a way back since `WorkspaceRestore`, and this is the same promise
/// one table over. The two are not the same act: restoring a workspace rebuilds a worktree from a
/// branch and can fail at it, while reopening a chat clears one column and cannot.
public enum SessionReopening {
    /// How many closed chats the menu offers.
    ///
    /// **A cap and no time window, and the reason is the bug rather than the tidiness.** A window
    /// ("closed in the last 30 days") reads better under a heading that says Recently Closed, and
    /// it buys that by adding a second way for a chat to fall out of reach: by nobody doing
    /// anything at all, which is exactly how those 13,872 messages went. With a cap alone, a chat
    /// only leaves this list once ten newer ones have been closed after it, which is something the
    /// user did rather than something the calendar did.
    ///
    /// Ten because this is a section of a menu rather than a window, and a menu that needs
    /// scrolling has stopped being one. The age is written on every row, so a chat closed in March
    /// says so and the heading misleads nobody.
    public static let limit = 10

    /// The rows to draw, newest first.
    ///
    /// **A chat with no messages is dropped rather than shown.** There is nothing in it to
    /// recover, the same menu offers a new chat three rows up, and a slot spent on an empty one is
    /// a slot taken from a conversation somebody wants back.
    ///
    /// The tie-break on id is not decoration. `archived_at` is a second-resolution column in
    /// SQLite's eyes only by accident, but two chats closed in one gesture (the last two tabs of a
    /// workspace, closed one after the other) land close enough that `sorted(by:)`, which is not
    /// stable, would draw them in a different order on different passes.
    public static func offered(_ chats: [ClosedChat]) -> [ClosedChat] {
        let ordered = chats
            .filter { $0.messageCount > 0 }
            .sorted { lhs, rhs in
                if lhs.closedAt != rhs.closedAt { return lhs.closedAt > rhs.closedAt }
                return lhs.id < rhs.id
            }
        return Array(ordered.prefix(limit))
    }

    /// Safari's words, because this is Safari's affordance and a reader has met it there.
    public static let sectionTitle = "Recently Closed"

    /// The row's first line.
    ///
    /// An untitled chat is drawn as the name a new one gets rather than as a blank row: a menu
    /// item with nothing written on it cannot be picked on purpose.
    public static func title(_ chat: ClosedChat) -> String {
        let trimmed = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PaneNaming.chat : trimmed
    }

    /// The row's second line: what ran it, how much is in it, and when it went.
    ///
    /// The count is `Counted`, so a chat with one message does not read "1 messages" and thirteen
    /// thousand of them carry a thousands separator. The order is what a reader weighs: the size
    /// is what decides whether this is the chat being looked for, and the age is what tells two
    /// chats of the same name apart.
    public static func subtitle(_ chat: ClosedChat, now: Date) -> String {
        [
            chat.agentKind.label,
            Counted.of(chat.messageCount, "message"),
            "closed " + age(of: chat.closedAt, from: now),
        ].joined(separator: " \u{00B7} ")
    }

    /// "2 hours ago", "yesterday", "last week".
    ///
    /// Written out so the labels are consistent across supported platforms.
    ///
    /// **One implementation rather than one per platform**, which is the other half of the fix: two
    /// would agree on the two cases the tests pin and drift everywhere else, and only one of them
    /// would ever be read. There is no `locale` any more either. It was always `.current`, nothing
    /// here varied by it, and Bloom writes British English throughout, so the parameter promised a
    /// choice that did not exist.
    ///
    /// The reason for a reference date rather than `Date.formatted(.relative(...))` is unchanged
    /// and is the reason this can be tested at all: that style is relative to `Date.now` and takes
    /// no reference, so nothing could pin the clock.
    public static func age(of date: Date, from now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())
        guard seconds >= 60 else { return "just now" }
        switch seconds {
        case ..<3_600: return Counted.of(seconds / 60, "minute") + " ago"
        case ..<86_400: return Counted.of(seconds / 3_600, "hour") + " ago"
        case ..<172_800: return "yesterday"
        case ..<604_800: return Counted.of(seconds / 86_400, "day") + " ago"
        case ..<1_209_600: return "last week"
        default: return Counted.of(seconds / 604_800, "week") + " ago"
        }
    }

    /// What Edit > Undo is undoing, straight after a chat is closed.
    ///
    /// Named for the act being reversed, which is what every Mac app puts after "Undo", and for
    /// `registerArchiveUndo`'s reason: SwiftUI's stock Edit menu draws a fixed title today and
    /// only takes the enabled state from the manager, so this reaches `undoActionName` rather than
    /// the menu. Spelling it out is what makes that menu correct the day the group is replaced.
    public static let undoActionName = "Close Chat"

    /// What to say when the row is not there to reopen.
    ///
    /// Reachable, rather than defensive: the menu is built from a reading taken when the pointer
    /// crossed the `+`, and the workspace behind it can be archived and its records deleted while
    /// the menu stands open. It follows `WorkspaceTrouble`'s rule of saying what is wrong and
    /// whether trying again would help.
    public static let missing = """
        That chat is no longer in Bloom's database, so there is nothing to reopen. \
        Trying again will not find it.
        """
}

/// The complete answer to an atomic reopen from the bounded Recently Closed list.
///
/// Kept in the core rather than expressed as wire errors so the store decides eligibility and
/// clears `archived_at` without another actor call slipping between those two acts.
enum OfferedSessionReopening: Sendable, Hashable {
    case reopened(Session)
    case missing
    case alreadyOpen
    case running
    case notTopLevel
    case notOffered
}

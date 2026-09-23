import Foundation

/// Whether a Cloud workspace's changes may be asked of its machine yet, from the setup state its
/// workspace record carries.
///
/// **Not knowing is not the same as knowing setup finished.** The Mac's gate used to be "setup is
/// pending or running", which a workspace whose record had not arrived yet passed, because its
/// setup state was nil. On a new workspace that is exactly the moment the machine is cloning, and
/// the Changes panel listed all 5,107 tracked files as deleted: the branch diff had been asked for
/// while `git clone` was still writing the checkout. So nil holds the read back as setting up does,
/// and the read happens when the record arrives and says otherwise.
///
/// The two are kept apart because they are drawn apart. Setting up has a sentence of its own in
/// the inspector; not knowing yet is the ordinary wait for a first answer, which the list already
/// draws as reading.
public enum CloudChangesReadiness: Equatable, Sendable {
    /// No workspace record yet, so nothing is known about setup.
    case unknown
    /// The machine is still making the worktree.
    case settingUp
    /// Setup has ended, however it ended, or never ran: the worktree is what it is going to be.
    case readable

    public static func of(setupState: String?) -> CloudChangesReadiness {
        guard let setupState else { return .unknown }
        return ["pending", "running"].contains(setupState) ? .settingUp : .readable
    }

    public var mayRead: Bool { self == .readable }

    /// Whether this is the moment to read: the gate has just opened. A list held back while the
    /// machine was cloning is read then, rather than when a turn next ends.
    public static func opened(from before: CloudChangesReadiness, to after: CloudChangesReadiness) -> Bool {
        !before.mayRead && after.mayRead
    }
}

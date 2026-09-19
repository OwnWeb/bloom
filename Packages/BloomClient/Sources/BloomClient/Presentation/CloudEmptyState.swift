import Foundation

/// What the app says where a Cloud workspace would be and there is none: in the sidebar's section,
/// in the centre column, and in the create sheet when it cannot offer a project.
///
/// **One shape, everywhere: a short title, one sentence that is true, and one button that does the
/// obvious next thing.** Every one of these used to be a line of grey text with nothing to press,
/// which leaves a first run with no way forward at all. Which sentence and which button it is
/// depends only on what the account says, so it is decided here and tested rather than being four
/// branches inside three views.
public struct CloudEmptyState: Sendable, Hashable {
    /// The one thing to do next. The window turns it into a button; nothing here draws.
    public enum Action: Sendable, Hashable {
        case signIn
        /// Somewhere on runbloom.app: the team's checklist, or the page for the step named.
        case open(URL?, title: String)
        case createWorkspace

        public var title: String {
            switch self {
            case .signIn: "Sign in to your Bloom account"
            case .open(_, let title): title
            case .createWorkspace: "Create your first Bloom Cloud workspace"
            }
        }
    }

    public var title: String
    public var sentence: String
    /// The steps a team still has, when that is what is in the way. Drawn under the sentence.
    public var steps: [String]
    public var action: Action?

    public init(title: String, sentence: String, steps: [String] = [], action: Action? = nil) {
        self.title = title
        self.sentence = sentence
        self.steps = steps
        self.action = action
    }

    /// Where a Cloud workspace list is empty. The order is the order a first run meets them:
    /// signed out, then early access, then the team's own checklist, then nothing created yet.
    ///
    /// - Parameters:
    ///   - isSignedIn: whether a Bloom account is signed in on this Mac.
    ///   - account: what runbloom.app said about it, once it has answered.
    public static func noWorkspaces(isSignedIn: Bool, account: RunbloomAccount?, environment: RunbloomEnvironment) -> CloudEmptyState {
        guard isSignedIn else {
            return CloudEmptyState(
                title: "Bloom Cloud workspaces",
                sentence: "A Bloom Cloud workspace runs in the cloud instead of on this Mac, so it keeps working while your Mac sleeps and your team can open it too.",
                action: .signIn
            )
        }
        guard let account else {
            return CloudEmptyState(title: "Bloom Cloud workspaces", sentence: "Reading your account from runbloom.app…")
        }
        // A team that is ready is the one to create in, whatever the others are missing.
        if account.teams.contains(where: \.isReadyForCloudWorkspaces) {
            return CloudEmptyState(
                title: "No Bloom Cloud workspaces yet",
                sentence: "Create one for a repository and a branch, and its agent starts work on a machine of its own.",
                action: .createWorkspace
            )
        }
        let notices = account.teams.compactMap { TeamSetupNotice(team: $0, environment: environment) }
        guard let notice = notices.first else {
            return CloudEmptyState(
                title: "Bloom Cloud workspaces",
                sentence: "None of your teams can create Bloom Cloud workspaces yet. runbloom.app says what each of them needs.",
                action: .open(environment.teamPage, title: TeamSetupNotice.genericButtonTitle)
            )
        }
        let isEarlyAccess = account.teams.allSatisfy { !$0.cloudWorkspacesEnabled }
        return CloudEmptyState(
            title: isEarlyAccess ? "Bloom Cloud workspaces are in early access" : "One more step first",
            sentence: notice.sentence,
            steps: notice.steps,
            action: .open(notice.page, title: notice.buttonTitle)
        )
    }

    /// The centre column with no Cloud workspace open: either pick one, or whatever the list's own
    /// empty state would have said.
    public static func nothingOpen(
        hasWorkspaces: Bool, isSignedIn: Bool, account: RunbloomAccount?, environment: RunbloomEnvironment
    ) -> CloudEmptyState {
        guard hasWorkspaces else { return noWorkspaces(isSignedIn: isSignedIn, account: account, environment: environment) }
        return CloudEmptyState(
            title: "No Bloom Cloud workspace open",
            sentence: "Choose one in the sidebar to read its conversation, or create another.",
            action: .createWorkspace
        )
    }

    /// A Cloud workspace that is in the list but cannot be opened by this reader, which a team's
    /// owners and administrators see for somebody else's private workspace.
    public static func privateWorkspace(ownerName: String?) -> CloudEmptyState {
        CloudEmptyState(
            title: "This Bloom Cloud workspace is private",
            sentence: "It belongs to \(ownerName ?? "somebody else"), and only they and the people they share it with can open it. You can still archive it.",
            action: nil
        )
    }

    /// A Cloud workspace the list no longer holds: archived here, archived by somebody else, or
    /// gone from a team this account left.
    public static let missingWorkspace = CloudEmptyState(
        title: "That Bloom Cloud workspace is gone",
        sentence: "It was archived, or it is no longer shared with you. Its machine and its conversation went with it.",
        action: .createWorkspace
    )
}

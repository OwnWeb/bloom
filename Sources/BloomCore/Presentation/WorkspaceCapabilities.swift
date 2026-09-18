import Foundation

/// What a workspace can do, so a view asks what is possible rather than what kind of workspace it
/// is showing.
///
/// **This exists so that `if cloud` never appears in a view.** The window draws one set of views
/// for a worktree on this Mac and for a workspace on a machine, and the handful of genuine
/// differences between them are these flags. A control whose capability is missing stays where it
/// is, greyed, with the sentence below saying why, because a control that disappears teaches
/// nobody anything and a control that fails after being pressed is worse.
///
/// **Only what a view actually asks.** It started with ten, one for everything a Cloud workspace
/// might not be able to do. Six went when the review pass found nothing asking them: history and
/// revert became true for both kinds once the machine could do them, and revealing a file, a
/// shell in a folder, transcript search and Keep Awake are answered by the thing itself (a file
/// with no path on this Mac, a terminal the machine offers or refuses) rather than by a flag
/// nobody read. A capability nothing asks is a claim nothing checks.
public struct WorkspaceCapabilities: Sendable, Hashable {
    /// One thing a workspace may or may not be able to do.
    public enum Capability: String, Sendable, Hashable, CaseIterable {
        /// Merge the pull request, or mark it ready for review, as the signed-in person.
        case managePullRequest
        /// Open the project's own app inside Bloom.
        case preview
        /// Write to a file from the diff: the in-place editor and the whole-file editor.
        case editFiles
        /// Leave notes on a diff to send with the next message.
        case reviewComments

        /// Why a Cloud workspace cannot do this, in one sentence, for the one place that draws a
        /// missing capability. Written as what is true rather than as an apology.
        public var cloudSentence: String {
            switch self {
            case .managePullRequest:
                "Only somebody who can push to this repository can merge its pull request or mark it ready for review."
            case .preview:
                "This Cloud workspace has no preview yet. It appears once the project's own app is running on it."
            case .editFiles:
                "Editing a file in a Cloud workspace is not built yet. Ask the agent to make the change, or edit it from the workspace's terminal."
            case .reviewComments:
                "Notes on a diff are not built for a Cloud workspace yet. Say what you want changed in the chat instead."
            }
        }
    }

    private var supported: Set<Capability>

    public init(_ supported: Set<Capability>) {
        self.supported = supported
    }

    public func has(_ capability: Capability) -> Bool { supported.contains(capability) }

    /// Everything, which is what a worktree on this Mac can do.
    public static let local = WorkspaceCapabilities(Set(Capability.allCases))

    /// What a Cloud workspace can do. The two that are known on the day are asked of runbloom.app
    /// and of the machine: whether this person may merge, and whether a preview is running. The
    /// two that are not built yet are off until they are, and turn on here rather than in a view.
    public static func cloud(
        managePullRequest: Bool = false, preview: Bool = false,
        editFiles: Bool = false, reviewComments: Bool = false
    ) -> WorkspaceCapabilities {
        var supported: Set<Capability> = []
        if managePullRequest { supported.insert(.managePullRequest) }
        if preview { supported.insert(.preview) }
        if editFiles { supported.insert(.editFiles) }
        if reviewComments { supported.insert(.reviewComments) }
        return WorkspaceCapabilities(supported)
    }
}

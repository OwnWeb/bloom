import Foundation

/// What a workspace can do, so a view asks what is possible rather than what kind of workspace it
/// is showing.
///
/// **This exists so that `if cloud` never appears in a view.** The window draws one set of views
/// for a worktree on this Mac and for a workspace on a machine, and the handful of genuine
/// differences between them are these flags. A control whose capability is missing stays where it
/// is, greyed, with the sentence below saying why, because a control that disappears teaches
/// nobody anything and a control that fails after being pressed is worse.
public struct WorkspaceCapabilities: Sendable, Hashable {
    /// One thing a workspace may or may not be able to do.
    public enum Capability: String, Sendable, Hashable, CaseIterable {
        /// Show a file in the Finder, or open it in another application on this Mac.
        case revealFiles
        /// Take a file or a hunk back to what it was.
        case revertChanges
        /// A shell on the same files, in the app.
        case terminal
        /// Merge the pull request, or mark it ready for review.
        case managePullRequest
        /// The commits on the branch, for the History tab.
        case history
        /// Find a conversation by what was said in it.
        case searchTranscripts
        /// Keep this Mac awake while the agent works.
        case keepAwake
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
            case .revealFiles:
                "These files are in the cloud rather than on this Mac, so there is nothing for the Finder to show. Open the file here, or on GitHub."
            case .revertChanges:
                "Taking a change back in a Cloud workspace is not built yet. Ask the agent to undo it, or do it from the workspace's terminal."
            case .terminal:
                "This Cloud workspace has no terminal for you yet."
            case .managePullRequest:
                "Merging and marking a pull request ready from a Cloud workspace is not built yet. The pull request itself is on GitHub."
            case .history:
                "The commits on this branch are not readable from a Cloud workspace yet."
            case .searchTranscripts:
                "Search does not reach Cloud workspace conversations yet. Open the workspace and read its chat."
            case .keepAwake:
                "A Cloud workspace runs in the cloud, so it keeps working whatever this Mac does. It sleeps by itself when nobody is using it and wakes when you are."
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

    /// What a Cloud workspace can do. The arguments are the things still being built on the other
    /// side of the wire, so each of them turns on here the day it lands rather than in a view.
    public static func cloud(
        history: Bool = false, revertChanges: Bool = false, searchTranscripts: Bool = false,
        preview: Bool = true, terminal: Bool = true, managePullRequest: Bool = false,
        editFiles: Bool = false, reviewComments: Bool = false
    ) -> WorkspaceCapabilities {
        var supported: Set<Capability> = []
        if history { supported.insert(.history) }
        if revertChanges { supported.insert(.revertChanges) }
        if searchTranscripts { supported.insert(.searchTranscripts) }
        if preview { supported.insert(.preview) }
        if terminal { supported.insert(.terminal) }
        if managePullRequest { supported.insert(.managePullRequest) }
        if editFiles { supported.insert(.editFiles) }
        if reviewComments { supported.insert(.reviewComments) }
        // Never, by construction: there is no worktree on this Mac to reveal, and nothing this Mac
        // does keeps a machine in the cloud awake.
        return WorkspaceCapabilities(supported)
    }
}

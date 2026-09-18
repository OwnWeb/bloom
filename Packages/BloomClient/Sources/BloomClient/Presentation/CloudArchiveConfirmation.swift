import BloomProtocol
import Foundation

/// What archiving a Cloud workspace would lose, in sentences, and whether to ask twice.
///
/// Archiving deletes the machine, and with it the conversation, so the sentence about the
/// conversation is always there, first. The rest is the machine's own measurement when it could be
/// asked (`archive_preview`), and runbloom.app's last summary when it could not: a machine that
/// never finished starting, or a workspace a team admin can archive but not open.
public struct CloudArchiveConfirmation: Sendable, Hashable {
    public var losses: [String]
    /// The id the machine checks its answer against, or nil when the machine was not asked.
    public var confirmationID: String?
    /// Whether anything but the conversation would be lost, which is what makes the button red.
    public var isDestructive: Bool

    public static let conversationSentence = "The conversation is deleted with the Cloud workspace. It cannot be restored."

    /// What is not lost, said as plainly as what is, so somebody archiving at the end of a day
    /// knows what they still have. **There is no export, by decision rather than by omission**: an
    /// archived Cloud workspace does not keep its conversation, and nothing here leaves room for
    /// one. See "Decided by the owner" in docs/REMOTE-WORKSPACES.md.
    public static let survivesSentence = "The branch stays on GitHub with everything pushed to it."

    /// What the sheet says when the machine could not be asked at all.
    ///
    /// **Unreachable is a normal path here rather than an error.** A machine that will not answer
    /// is exactly when somebody wants out of the workspace, and archiving is runbloom.app's work:
    /// it needs no machine and never did. So the sheet says what it could not find out, and
    /// archives.
    public static let unaskedSentence =
        "The machine did not answer, so this is what runbloom.app last heard about it. Archiving stops and deletes it anyway."

    public init(preview: ArchivePreviewRecord) {
        var losses = [Self.conversationSentence]
        if preview.isAgentRunning { losses.append("An agent is still working. It will be stopped.") }
        if preview.hasUncommittedChanges { losses.append("There are uncommitted changes.") }
        if !preview.untrackedFiles.isEmpty {
            losses.append(preview.untrackedFiles.count == 1
                ? "One untracked file: \(preview.untrackedFiles[0])."
                : "\(preview.untrackedFiles.count) untracked files.")
        }
        if preview.unpushedCommits > 0 {
            losses.append(preview.unpushedCommits == 1 ? "One commit has not been pushed." : "\(preview.unpushedCommits) commits have not been pushed.")
        }
        if preview.detachedCommits > 0 {
            losses.append(preview.detachedCommits == 1 ? "One commit is on no branch." : "\(preview.detachedCommits) commits are on no branch.")
        }
        self.losses = losses
        confirmationID = preview.confirmationID
        isDestructive = losses.count > 1
    }

    /// When the machine could not be asked. The summary is as old as the machine's last report, so
    /// it is said as that.
    public init(summary: CloudWorkspaceSummary?) {
        var losses = [Self.conversationSentence]
        if let diff = summary?.diff, diff.files > 0 {
            losses.append("When it last reported, \(diff.files == 1 ? "one file had" : "\(diff.files) files had") changes. Anything not pushed is lost.")
        } else {
            losses.append("Anything that was not pushed is lost.")
        }
        self.losses = losses
        confirmationID = nil
        isDestructive = true
    }
}

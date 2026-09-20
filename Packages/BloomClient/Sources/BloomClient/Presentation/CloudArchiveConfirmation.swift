import BloomProtocol
import Foundation

/// What deleting a Cloud workspace would lose, in sentences, and whether to ask twice.
///
/// Archiving deletes the machine, and with it the conversation, so the sentence about the
/// conversation is always there, first. The rest is the machine's own measurement when it could be
/// asked (`archive_preview`), and runbloom.app's last summary when it could not: a machine that
/// never finished starting, or a workspace a team admin can archive but not open.
public struct CloudArchiveConfirmation: Sendable, Hashable {
    public var losses: [String]
    /// The id the machine checks its answer against, or nil when the machine was not asked.
    public var confirmationID: String?
    /// Whether deleting this workspace is destructive. It always is, even when the worktree is
    /// clean, because the machine and conversation have no archive or restore path.
    public var isDestructive: Bool

    public static let conversationSentence =
        "This permanently deletes the machine, its worktree, the conversation and any unpushed work. Nothing can be restored."

    /// What is not lost, said as plainly as what is, so somebody archiving at the end of a day
    /// knows what they still have. **There is no export, by decision rather than by omission**: an
    /// archived Cloud workspace does not keep its conversation, and nothing here leaves room for
    /// one. See "Decided by the owner" in docs/REMOTE-WORKSPACES.md.
    public static let survivesSentence = "The branch and everything already pushed to it remain on GitHub."

    /// What the sheet says when the machine could not be asked at all.
    ///
    /// **Unreachable is a normal path here rather than an error.** A machine that will not answer
    /// is exactly when somebody wants out of the workspace, and archiving is runbloom.app's work:
    /// it needs no machine and never did. So the sheet says what it could not find out, and
    /// archives.
    public static let unaskedSentence =
        "The machine did not answer. These details are from its latest report to runbloom.app."

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
        isDestructive = true
    }

    /// When the machine could not be asked. The summary is as old as the machine's last report, so
    /// it is said as that.
    public init(summary: CloudWorkspaceSummary?) {
        var losses = [Self.conversationSentence]
        if let diff = summary?.diff, diff.files > 0 {
            losses.append("At its latest report, \(diff.files == 1 ? "one file had" : "\(diff.files) files had") changes.")
        }
        self.losses = losses
        confirmationID = nil
        isDestructive = true
    }
}

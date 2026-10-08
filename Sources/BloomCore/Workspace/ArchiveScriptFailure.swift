import Foundation

/// What the owner is told when a project's archive script fails, and what pressing "Archive
/// Anyway" costs them.
///
/// A failing script stops the archive on purpose: containers still running or a database still
/// there are mess with nothing left to clean it up from once the worktree is gone. But the script
/// failing is not always fixable right away (a Docker daemon that is stuck, a resource that is gone
/// for good), and with no way past it the only exit was deleting the worktree by hand outside
/// Bloom. So the refusal carries the way out, and the words say plainly what it leaves behind.
public struct ArchiveScriptFailure: Equatable, Sendable {
    public let title = "The archive script failed"
    public let confirmLabel = "Archive Anyway"
    public let cancelLabel = "Keep Workspace"
    public let message: String

    /// Nil for any error that is not the archive script failing, so the caller has one place to
    /// ask rather than a `switch` of its own.
    public init?(_ error: WorkspaceError, workspaceName: String) {
        let reason: String
        switch error {
        case .archiveScriptFailed(let status, let output):
            // The tail is where a script says why it gave up.
            let tail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(Self.outputLimit)
            reason = "The script exited with status \(status).\n\n\(tail)"
        case .archiveScriptIncomplete(let failure):
            reason = "The script did not finish: \(failure.description)"
        default:
            return nil
        }
        message = "\u{201C}\(workspaceName)\u{201D} is still here: its worktree and its branch are "
            + "untouched. Any agent it was running has been stopped.\n\n\(reason)\n\n"
            + "Archiving anyway skips the script. Whatever it was meant to remove (databases, "
            + "containers and so on) will be left behind."
    }

    private static let outputLimit = 1_000
}

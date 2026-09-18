import BloomProtocol
import Foundation

/// Discard, for a Cloud workspace: a whole file back to the review's baseline, or one hunk of it.
///
/// **A hunk is named by its own patch, not by an index.** The client has the hunk's text already,
/// from `review_patch`, and the file may have moved on since: an index would silently discard a
/// different hunk, while the patch either still matches what is on the machine or it does not, and
/// "it does not" is the answer a person can act on. The match is the hunk's header and every one of
/// its lines, so a hunk that grew, shrank or moved is refused rather than guessed at.
///
/// **What the word means is the scope's, and both meanings are git's own.** In the branch and
/// uncommitted scopes it is the whole change, put back to the baseline the reader is comparing
/// against. In the staged scope it is `git restore --staged`: the change leaves the index, the
/// worktree keeps it, and nothing anybody wrote is destroyed, so the client labels it Unstage. In
/// the unstaged scope it is `git restore`, throwing the worktree's copy away, which is the only
/// thing it can mean there and the only one of the four where something is actually lost.
public enum RemoteDiscard {
    /// Which of those two a scope asks for, which is the whole of the difference between them.
    static func intent(for scope: BloomProtocol.DiffScope) -> HunkDiscard.Intent {
        scope == .staged ? .unstage : .discard
    }

    public static func revertFile(workspace: Workspace, path: String, scope: BloomProtocol.DiffScope) async throws {
        let (file, base) = try await find(workspace: workspace, path: path, scope: scope)
        guard file.change != .untracked else {
            throw RemoteFailure.invalid("This file is not tracked by git, so there is nothing to put back. Delete it instead.")
        }
        switch scope {
        case .staged: try await Git.unstageFile(file, worktree: workspace.path)
        case .unstaged: try await Git.restoreWorktreeFile(file, worktree: workspace.path)
        case .branch, .uncommitted: try await Git.revertTrackedFile(file, worktree: workspace.path, base: base)
        }
    }

    public static func discardHunk(workspace: Workspace, path: String, scope: BloomProtocol.DiffScope, patch: String) async throws {
        let (file, base) = try await find(workspace: workspace, path: path, scope: scope)
        guard let wanted = hunk(in: patch) else {
            throw RemoteFailure.invalid("That is not one hunk of a patch.")
        }
        // The same comparison the client read its hunk from. In the branch and uncommitted scopes
        // that is one diff against the baseline, staged and unstaged together, so a hunk is matched
        // and reversed in the worktree and in the index where it applies. In the two layer scopes
        // the file carries its layer, which is what `Git.patch` reads to pick a side of the index.
        let comparison: DiffScope = file.layer == nil ? .all : .uncommitted
        let current = try await Git.patch(worktree: workspace.path, base: base, file: file, scope: comparison)
        guard let match = DiffParser.parse(current).flatMap(\.hunks).first(where: { same($0, wanted) }) else {
            throw RemoteFailure(.conflict, "This part of the file has changed since it was read. Refresh the diff and try again.")
        }
        do {
            try await Git.discardHunk(
                match, of: file, worktree: workspace.path, base: base,
                scope: comparison, intent: intent(for: scope)
            )
        } catch let refusal as HunkDiscardRefusal {
            throw RemoteFailure(.conflict, sentence(for: refusal))
        }
    }

    /// The file as the review lists it, so a discard and the diff somebody is reading are the same
    /// comparison, with its layer (staged, unstaged) when the scope separates them.
    private static func find(
        workspace: Workspace, path: String, scope: BloomProtocol.DiffScope
    ) async throws -> (ChangedFile, String) {
        try RemoteReview.validateRelativePath(path)
        let base = try await RemoteReview.base(workspace: workspace, scope: scope)
        // The list the scope shows, one row per path. The branch and uncommitted scopes are one row
        // per path across both layers, because a list split by staging layer would name a file
        // changed in both twice and the first of them is not the diff the client read; the two
        // layer scopes are one layer each, and their rows say so.
        let files = try await RemoteReview.changes(workspace: workspace, base: base, scope: scope)
        guard let file = files.first(where: { $0.path == path }) else {
            throw RemoteFailure.notFound("This file has no changes in the selected scope. Refresh the file list.")
        }
        return (file, base)
    }

    static func hunk(in patch: String) -> DiffHunk? {
        let parsed = DiffParser.parse(patch).flatMap(\.hunks)
        // A bare hunk (`@@ …` with no `diff --git` above it) is what a client holds after reading
        // one from a file's patch, so it is parsed on its own too.
        if parsed.count == 1 { return parsed[0] }
        guard parsed.isEmpty, patch.hasPrefix("@@") else { return nil }
        let framed = "diff --git a/x b/x\n--- a/x\n+++ b/x\n" + patch
        let hunks = DiffParser.parse(framed).flatMap(\.hunks)
        return hunks.count == 1 ? hunks[0] : nil
    }

    static func same(_ one: DiffHunk, _ other: DiffHunk) -> Bool {
        one.oldStart == other.oldStart && one.oldCount == other.oldCount
            && one.newStart == other.newStart && one.newCount == other.newCount
            && one.lines.map(\.text) == other.lines.map(\.text)
            && one.lines.map(\.kind) == other.lines.map(\.kind)
    }

    static func sentence(for refusal: HunkDiscardRefusal) -> String {
        switch refusal {
        case .notOffered: "This hunk cannot be discarded on its own."
        case .changed: "This part of the file has changed since it was read. Refresh the diff and try again."
        case .doesNotApply(let detail): detail.isEmpty ? "Git would not put this hunk back." : "Git would not put this hunk back: \(detail)"
        }
    }
}

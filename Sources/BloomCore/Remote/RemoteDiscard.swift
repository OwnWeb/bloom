import BloomProtocol
import Foundation

/// Discard, for a Cloud workspace: a whole file back to the review's baseline, or one hunk of it.
///
/// **A hunk is named by its own patch, not by an index.** The client has the hunk's text already,
/// from `review_patch`, and the file may have moved on since: an index would silently discard a
/// different hunk, while the patch either still matches what is on the machine or it does not, and
/// "it does not" is the answer a person can act on. The match is the hunk's header and every one of
/// its lines, so a hunk that grew, shrank or moved is refused rather than guessed at.
public enum RemoteDiscard {
    /// Reverting and discarding take the two scopes a client reads a whole file's diff from. The
    /// staged and unstaged scopes are for reading: what "discard" means in each of them (unstage,
    /// or throw the worktree's copy away) is a decision for the window that offers the button, and
    /// offering it here before that decision is made would be guessing at it.
    static func requireWholeFileScope(_ scope: BloomProtocol.DiffScope) throws {
        guard scope == .branch || scope == .uncommitted else {
            throw RemoteFailure.invalid("Discarding reads the branch or uncommitted comparison, not one staging layer.")
        }
    }

    public static func revertFile(workspace: Workspace, path: String, scope: BloomProtocol.DiffScope) async throws {
        try requireWholeFileScope(scope)
        let (file, base) = try await find(workspace: workspace, path: path, scope: scope)
        guard file.change != .untracked else {
            throw RemoteFailure.invalid("This file is not tracked by git, so there is nothing to put back. Delete it instead.")
        }
        try await Git.revertTrackedFile(file, worktree: workspace.path, base: base)
    }

    public static func discardHunk(workspace: Workspace, path: String, scope: BloomProtocol.DiffScope, patch: String) async throws {
        try requireWholeFileScope(scope)
        let (file, base) = try await find(workspace: workspace, path: path, scope: scope)
        guard let wanted = hunk(in: patch) else {
            throw RemoteFailure.invalid("That is not one hunk of a patch.")
        }
        // The same comparison the client read its hunk from: `review_patch` measures uncommitted
        // work against HEAD as one diff, staged and unstaged together, so that is what a hunk is
        // matched against and reversed in (the worktree, and the index where it applies).
        let current = try await Git.patch(worktree: workspace.path, base: base, file: file, scope: .all)
        guard let match = DiffParser.parse(current).flatMap(\.hunks).first(where: { same($0, wanted) }) else {
            throw RemoteFailure(.conflict, "This part of the file has changed since it was read. Refresh the diff and try again.")
        }
        do {
            try await Git.discardHunk(match, of: file, worktree: workspace.path, base: base, scope: .all)
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
        // The list the review shows, one row per path. A list split by staging layer would name a
        // file changed in both twice, and the first of them is not the diff the client read.
        let files = try await RemoteReview.changes(workspace: workspace, base: base)
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

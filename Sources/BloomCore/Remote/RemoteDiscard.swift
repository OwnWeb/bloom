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
    public static func revertFile(workspace: Workspace, path: String, scope: BloomProtocol.DiffScope) async throws {
        let (file, base) = try await find(workspace: workspace, path: path, scope: scope)
        guard file.change != .untracked else {
            throw RemoteFailure.invalid("This file is not tracked by git, so there is nothing to put back. Delete it instead.")
        }
        try await Git.revertTrackedFile(file, worktree: workspace.path, base: base)
    }

    public static func discardHunk(workspace: Workspace, path: String, scope: BloomProtocol.DiffScope, patch: String) async throws {
        let (file, base) = try await find(workspace: workspace, path: path, scope: scope)
        guard let wanted = hunk(in: patch) else {
            throw RemoteFailure.invalid("That is not one hunk of a patch.")
        }
        // The layer's own patch, so a staged hunk is matched against HEAD to index rather than
        // against the worktree, which is the comparison the client was reading.
        let current = try await Git.patch(worktree: workspace.path, base: base, file: file, scope: scope.git(file: file))
        guard let match = DiffParser.parse(current).flatMap(\.hunks).first(where: { same($0, wanted) }) else {
            throw RemoteFailure(.conflict, "This part of the file has changed since it was read. Refresh the diff and try again.")
        }
        do {
            try await Git.discardHunk(match, of: file, worktree: workspace.path, base: base, scope: scope.git(file: file))
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
        // Uncommitted work is read with its staging layers, because a discard writes the worktree,
        // the index or both depending on which layer the hunk came from.
        let files = scope == .uncommitted
            ? try await Git.changedFiles(worktree: workspace.path, base: base, scope: .uncommitted)
            : try await RemoteReview.changes(workspace: workspace, base: base)
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

extension BloomProtocol.DiffScope {
    /// The comparison git is asked for. `uncommitted` keeps the file's own staging layer, which is
    /// what decides whether a discard writes the worktree, the index or both.
    func git(file: ChangedFile) -> BloomCore.DiffScope {
        self == .uncommitted ? .uncommitted : .all
    }
}

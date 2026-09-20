import BloomProtocol
import Foundation

/// The branch's commits, and one commit's files, for the History tab.
///
/// The Mac reads exactly this from `git log` for a local workspace, so the same rows are drawn for
/// a Cloud workspace: `Git.branchCommits` is the one that parses it, and this only shapes what it
/// answers for the wire and says which commits the remote already has.
///
/// **A page does not carry each commit's files.** A hundred rows would be a hundred diffs, and only
/// the row somebody opens needs them, which `commit_files` answers for one commit.
public enum RemoteHistory {
    public static let pageLimit = 100

    public static func page(workspace: Workspace, limit: Int?, before: String?) async throws -> HistoryRecord {
        let wanted = min(max(limit ?? 50, 1), pageLimit)
        // One more than the base branch would show, so a `before` that names the last commit of a
        // page still has something to page into.
        let all = try await Git.branchCommits(worktree: workspace.path, base: workspace.baseBranch, limit: BranchCommitList.limit)
        var commits = all.commits
        if let before {
            guard let index = commits.firstIndex(where: { $0.sha == before }) else {
                throw RemoteFailure.notFound("That commit is not on this branch any more.")
            }
            commits = Array(commits[(index + 1)...])
        }
        let page = Array(commits.prefix(wanted))
        let pushed = try await pushedShas(workspace: workspace, commits: page)
        return HistoryRecord(
            commits: page.map { commit in commit.record(pushed: pushed.map { $0.contains(commit.sha) }) },
            hasMore: commits.count > page.count || all.isTruncated
        )
    }

    public static func files(workspace: Workspace, sha: String) async throws -> [ChangedFileRecord] {
        let (_, files) = try await commit(workspace: workspace, sha: sha)
        return files.map { $0.record(contentRevision: nil) }
    }

    /// One file's diff inside one commit, in the same patch text and the same file vocabulary the
    /// other scopes answer with, so one parser draws every diff a client shows.
    ///
    /// An unknown commit or a file that commit did not touch is a refusal rather than an empty
    /// patch: empty is what a commit that changed nothing would answer, and a reader cannot tell
    /// those apart.
    public static func patch(workspace: Workspace, sha: String, path: String) async throws -> PatchSnapshotRecord {
        let (commit, files) = try await commit(workspace: workspace, sha: sha)
        guard let file = files.first(where: { $0.path == path || $0.oldPath == path }) else {
            throw RemoteFailure.notFound("This file did not change in that commit.")
        }
        let patch = try await Git.patch(worktree: workspace.path, base: workspace.baseBranch, file: file, scope: .commit(commit))
        return PatchSnapshotRecord(revision: commit.sha, patch: patch)
    }

    /// The commit as git has it here, with the files it changed, or a refusal naming which of the
    /// two went wrong.
    private static func commit(workspace: Workspace, sha: String) async throws -> (BranchCommit, [ChangedFile]) {
        guard sha.count >= 7, sha.count <= 64, sha.allSatisfy({ $0.isHexDigit }) else {
            throw RemoteFailure.invalid("That is not a commit.")
        }
        let commit = BranchCommit(sha: sha, subject: "", author: "", date: Date(), body: "", parents: [])
        guard try await Git.containsCommit(commit, worktree: workspace.path) else {
            throw RemoteFailure.notFound("That commit is not on this branch any more.")
        }
        return (commit, try await Git.changedFiles(worktree: workspace.path, base: workspace.baseBranch, scope: .commit(commit)))
    }

    /// Which of these commits the branch's remote already has, or nil when there is no remote
    /// branch yet: "not pushed" and "nowhere to push to" are different things to a reader.
    private static func pushedShas(workspace: Workspace, commits: [BranchCommit]) async throws -> Set<String>? {
        guard !commits.isEmpty, Git.isValidBranchName(workspace.branch) else { return nil }
        let remote = "refs/remotes/origin/" + workspace.branch
        let exists = try await Git.run(["rev-parse", "--verify", "--quiet", remote], in: workspace.path)
        guard exists.status == 0 else { return nil }
        let listed = try await Git.run(["rev-list", remote], in: workspace.path)
        guard listed.ok else { return nil }
        return Set(listed.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
    }
}

extension BranchCommit {
    func record(pushed: Bool?) -> CommitRecord {
        CommitRecord(sha: sha, subject: subject, authorName: author, authorEmail: authorEmail, date: date,
                     body: body, parents: parents, pushed: pushed)
    }
}

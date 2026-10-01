import Foundation

public enum LocalMergeOutcome: Sendable, Equatable {
    case merged
    case alreadyMerged
}

public struct LocalMergeFailure: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Merges a workspace's committed branch into the local base checkout, without a remote or gh.
extension Git {
    public static func mergeLocally(
        branch: String, from worktree: String, into base: String, at repo: String
    ) async throws -> LocalMergeOutcome {
        try validate(branch: branch)
        try validate(branch: base)
        guard branch != base else {
            throw localMergeError("The workspace is already on \(base).")
        }
        guard try await currentBranch(of: worktree) == branch else {
            throw localMergeError("The workspace is no longer checked out on \(branch).")
        }
        guard try await currentBranch(of: repo) == base else {
            throw localMergeError("Open \(base) in the project's main checkout before merging locally.")
        }
        guard try await check(["status", "--porcelain"], in: worktree).stdout.isEmpty else {
            throw localMergeError("Commit or discard the workspace's uncommitted changes before merging.")
        }
        guard try await check(["status", "--porcelain"], in: repo).stdout.isEmpty else {
            throw localMergeError("The \(base) checkout has uncommitted changes. Clear them before merging.")
        }
        guard await revision(of: "refs/heads/\(branch)", in: repo) != nil else {
            throw localMergeError("The local branch \(branch) no longer exists.")
        }
        let mergeHead = try await run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo)
        guard !mergeHead.ok else {
            throw localMergeError("Finish or abort the merge already in progress on \(base).")
        }
        if await isAncestor("refs/heads/\(branch)", of: "refs/heads/\(base)", in: repo) {
            return .alreadyMerged
        }

        let arguments = ["merge", "--no-edit", "--no-ff", "refs/heads/\(branch)"]
        let result = try await run(arguments, in: repo)
        guard result.ok else {
            let pending = try await run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo)
            if pending.ok {
                let abort = try await run(["merge", "--abort"], in: repo)
                guard abort.ok else {
                    throw localMergeError("The merge failed and could not be aborted. Resolve the merge in \(repo). \(abort.stderr)")
                }
            }
            throw error(arguments, result.status, result.stderr, result.stdout)
        }
        return .merged
    }

    private static func localMergeError(_ message: String) -> ShellError {
        ShellError(command: "git merge", status: 1, stderr: message)
    }
}

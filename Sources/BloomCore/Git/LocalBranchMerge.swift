import Foundation

/// A local merge changes only the checked-out base branch. It never fetches, pushes, or calls gh.
public struct LocalMergePlan: Sendable, Equatable {
    public let source: String
    public let target: String
    public let sourcePath: String
    public let targetPath: String
    public let sourceRevision: String
    public let targetRevision: String
}

public enum LocalMergeFailure: Error, Sendable {
    case refused(String)
    case conflicts(String)

    public var message: String {
        switch self {
        case .refused(let reason): reason
        case .conflicts(let reason): reason
        }
    }
}

/// Serialises merges started by Bloom and checks both checkouts again at the final press.
public actor LocalBranchMerger {
    public static let shared = LocalBranchMerger()

    private var isMerging = false

    public func prepare(source: String, target: String, in sourcePath: String) async throws -> LocalMergePlan {
        let localTarget = try await Git.repositoryContext(in: sourcePath, baseBranch: target).baseBranch
        guard Git.isValidBranchName(source), Git.isValidBranchName(localTarget), source != localTarget else {
            throw LocalMergeFailure.refused("Choose two different local branches to merge.")
        }
        guard try await Git.currentBranch(of: sourcePath) == source else {
            throw LocalMergeFailure.refused("The workspace is no longer checked out on \(source).")
        }
        let entries = try await Git.worktrees(of: sourcePath)
        guard let destination = entries.first(where: { $0.branch == localTarget && !$0.isBare && !$0.isPrunable }) else {
            throw LocalMergeFailure.refused("Check out \(localTarget) in a local worktree before merging into it.")
        }
        guard !destination.isLocked else {
            throw LocalMergeFailure.refused("The checkout for \(localTarget) is locked.")
        }
        guard try await Git.currentBranch(of: destination.path) == localTarget else {
            throw LocalMergeFailure.refused("The target checkout is no longer on \(localTarget).")
        }
        guard !(await Git.hasOperationInProgress(in: sourcePath)),
              !(await Git.hasOperationInProgress(in: destination.path)) else {
            throw LocalMergeFailure.refused("Finish the git operation already in progress before merging.")
        }
        guard try await isClean(sourcePath) else {
            throw LocalMergeFailure.refused("Commit or remove uncommitted and untracked files in \(source) before merging.")
        }
        guard try await isClean(destination.path) else {
            throw LocalMergeFailure.refused("Commit or remove uncommitted and untracked files in \(localTarget) before merging.")
        }
        let contained = try await Git.run(
            ["merge-base", "--is-ancestor", "refs/heads/\(source)", "refs/heads/\(localTarget)"],
            in: sourcePath
        )
        if contained.ok {
            throw LocalMergeFailure.refused("\(localTarget) already contains every commit on \(source).")
        }
        guard contained.status == 1 else {
            throw LocalMergeFailure.refused(contained.stderr)
        }
        return LocalMergePlan(
            source: source, target: localTarget, sourcePath: sourcePath, targetPath: destination.path,
            sourceRevision: try await Git.headSHA(of: sourcePath),
            targetRevision: try await Git.headSHA(of: destination.path)
        )
    }

    public func merge(_ plan: LocalMergePlan) async throws {
        guard !isMerging else { throw LocalMergeFailure.refused("Another local merge is already running.") }
        isMerging = true
        defer { isMerging = false }

        let current = try await prepare(source: plan.source, target: plan.target, in: plan.sourcePath)
        guard current == plan else {
            throw LocalMergeFailure.refused("A checkout or branch changed since this merge was prepared. Review it again.")
        }

        // Use the full local ref to avoid a same-named remote or path. --no-edit uses git's
        // standard merge message; --no-ff leaves a visible merge commit even when fast-forward is possible.
        let arguments = ["merge", "--no-ff", "--no-edit", "refs/heads/\(plan.source)"]
        let result = try await Git.run(arguments, in: plan.targetPath)
        guard result.ok else {
            if let after = try? await Git.headSHA(of: plan.targetPath), after != plan.targetRevision {
                throw LocalMergeFailure.refused(
                    "Git reported an error after \(plan.target) moved. Inspect the target checkout "
                        + "before trying again. " + result.stderr
                )
            }
            if await Git.hasOperationInProgress(in: plan.targetPath) {
                let aborted = try? await Git.run(["merge", "--abort"], in: plan.targetPath)
                if aborted?.ok == true {
                    throw LocalMergeFailure.conflicts(
                        "Git could not merge \(plan.source) into \(plan.target). The merge was aborted, "
                            + "and both branches are unchanged. Resolve the conflict with the agent or git. "
                            + result.stderr
                    )
                }
                throw LocalMergeFailure.conflicts(
                    "Git could not merge \(plan.source) into \(plan.target), and could not abort. "
                        + "Open the \(plan.target) checkout to resolve or abort the merge. " + result.stderr
                )
            }
            throw LocalMergeFailure.refused(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func isClean(_ path: String) async throws -> Bool {
        try await Git.checkRaw(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: path)
            .stdout.isEmpty
    }
}

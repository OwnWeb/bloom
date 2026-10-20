import Foundation

/// Moving a workspace's base once it exists, for a branch rebased onto another one after it was
/// created. A base left behind measured the Changes tab, the diff stat and Create PR against the
/// wrong branch: 495 files for a branch that changed 32.
public enum BaseBranchChange {
    /// Every branch this clone knows, local or on the primary remote, less the workspace's own.
    public static func load(repoPath: String, excluding branch: String) async -> [String] {
        // Empty for a workspace with no worktree on this Mac, and git would answer for the
        // process's own directory instead.
        guard !repoPath.isEmpty else { return [] }
        async let local = Git.branches(of: repoPath)
        async let remote = Git.remoteBranches(of: repoPath)
        async let remoteNames = Git.remoteNames(of: repoPath)
        let primary = WorkspaceStartContext.primaryRemoteBranches(
            references: (try? await remote) ?? [], remoteNames: (try? await remoteNames) ?? []
        )
        return options(local: (try? await local) ?? [], remote: primary, excluding: branch)
    }

    static func options(local: [String], remote: [String], excluding branch: String) -> [String] {
        Set(local + remote).subtracting(["", branch])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Writes the base where git keeps it too, as creating the workspace did: `gh pr create`
    /// without `--base` reads `gh-merge-base`, and so does every context resolved without a base.
    public static func record(_ base: String, for workspace: Workspace) async throws {
        let context = try await Git.repositoryContext(in: workspace.path, baseBranch: base, branch: workspace.branch)
        try await Git.recordBase(context, for: workspace.branch, in: workspace.path)
    }

    /// Why `choice` cannot be the base, or nil when it can. Asked against a fresh listing, because
    /// the menu's may be minutes old.
    public static func refusal(of choice: String, branch: String, available: [String]) -> String? {
        if choice == branch {
            return "\(choice) is this workspace's own branch, so there would be nothing to compare."
        }
        if !available.contains(choice) {
            return "\(choice) is not a branch of this repository or of its remote."
        }
        return nil
    }
}

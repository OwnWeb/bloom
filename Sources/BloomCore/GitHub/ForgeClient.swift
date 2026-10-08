import Foundation

/// The pull request operations more than one forge answers. Each requirement takes only what its
/// callers pass, so every default stays on `GitHub` rather than being restated here.
public protocol ForgeClient {
    static func access() async -> GitHubAccess
    static func readPullRequest(for workspace: Workspace, maxAge: Duration) async -> PullRequestRead
    static func pullRequest(for workspace: Workspace, maxAge: Duration) async throws -> PullRequest?
    static func pullRequest(forBranch branch: String, worktree: String) async throws -> PullRequest?
    static func checks(for workspace: Workspace) async throws -> [CheckRun]?
    static func markReadyForReview(_ pullRequest: PullRequest, worktree: String) async throws
    static func checkRunLog(_ target: CheckFailureHandoff.LogTarget, worktree: String) async throws -> String
    static func openPullRequests(repoPath: String) async throws -> [PullRequestListing]
    static func pullRequestSummary(number: Int, repoPath: String) async throws -> PullRequestListing
    static func repositorySlug(repoPath: String) async -> String?
    static func checkoutPullRequest(number: Int, into worktree: String, localBranch: String) async throws
}

/// `GitHub` as a `ForgeClient`. It only forwards.
public enum GitHubForge: ForgeClient {
    public static func access() async -> GitHubAccess {
        await GitHub.access()
    }

    public static func readPullRequest(for workspace: Workspace, maxAge: Duration) async -> PullRequestRead {
        await GitHub.readPullRequest(for: workspace, maxAge: maxAge)
    }

    public static func pullRequest(for workspace: Workspace, maxAge: Duration) async throws -> PullRequest? {
        try await GitHub.pullRequest(for: workspace, maxAge: maxAge)
    }

    public static func pullRequest(forBranch branch: String, worktree: String) async throws -> PullRequest? {
        try await GitHub.pullRequest(forBranch: branch, worktree: worktree)
    }

    public static func checks(for workspace: Workspace) async throws -> [CheckRun]? {
        try await GitHub.checks(for: workspace)
    }

    public static func markReadyForReview(_ pullRequest: PullRequest, worktree: String) async throws {
        try await GitHub.markReadyForReview(pullRequest, worktree: worktree)
    }

    public static func checkRunLog(
        _ target: CheckFailureHandoff.LogTarget, worktree: String
    ) async throws -> String {
        try await GitHub.checkRunLog(target, worktree: worktree)
    }

    public static func openPullRequests(repoPath: String) async throws -> [PullRequestListing] {
        try await GitHub.openPullRequests(repoPath: repoPath)
    }

    public static func pullRequestSummary(number: Int, repoPath: String) async throws -> PullRequestListing {
        try await GitHub.pullRequestSummary(number: number, repoPath: repoPath)
    }

    public static func repositorySlug(repoPath: String) async -> String? {
        await GitHub.repositorySlug(repoPath: repoPath)
    }

    public static func checkoutPullRequest(number: Int, into worktree: String, localBranch: String) async throws {
        try await GitHub.checkoutPullRequest(number: number, into: worktree, localBranch: localBranch)
    }
}

/// Which forge a repository's pull requests are asked of.
///
/// Every repository answers GitHub, which is the whole of what Bloom speaks today. The directory
/// is taken now so that callers already say which repository they mean when a second answer
/// arrives.
public enum ForgeResolver {
    public static func client(for directory: String) async -> any ForgeClient.Type {
        GitHubForge.self
    }
}

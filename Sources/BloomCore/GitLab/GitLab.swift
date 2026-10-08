import Foundation

/// The glab boundary, read as `PullRequest` and `CheckRun`.
///
/// Reads use `glab api` on the versioned REST API with the host and project named, rather than
/// glab's own JSON and remote guessing. No cache yet: a read is two or three small calls.
public enum GitLab: ForgeClient {
    @TaskLocal static var commandOverride: (@Sendable ([String], String?) async throws -> ShellResult)?

    private static let readTimeout = Duration.seconds(20)
    /// Checking out fetches objects, so it gets what `gh pr checkout` gets.
    private static let checkoutTimeout = Duration.seconds(120)
    private static let logTimeout = Duration.seconds(90)
    private static let candidateLimit = 20
    private static let jobLimit = 100
    private static let listLimit = 30

    public static func access(in directory: String) async -> GitHubAccess {
        guard commandOverride != nil || Shell.which("glab") != nil else { return .notInstalled }
        guard let project = await project(in: directory),
              let result = try? await run(["auth", "status", "--hostname", project.host], cwd: nil)
        else { return .signedOut }
        return result.ok ? .ready : .signedOut
    }

    public static func readPullRequest(for workspace: Workspace, maxAge: Duration) async -> PullRequestRead {
        guard commandOverride != nil || Shell.which("glab") != nil else {
            return .unavailable(GitHubReadFailure(
                reason: .unavailable, message: "Install the GitLab CLI to refresh merge requests."
            ))
        }
        do { return .current(try await pullRequest(for: workspace, maxAge: maxAge)) } catch {
            let failure = GitHubReadFailure.classify(error)
            let refused = failure.reason == .authentication || ((error as? ShellError)?.stderr.contains("401") ?? false)
            return .unavailable(refused ? GitHubReadFailure(
                reason: .authentication, message: "Connect GitLab again to refresh merge requests."
            ) : failure)
        }
    }

    public static func pullRequest(for workspace: Workspace, maxAge: Duration) async throws -> PullRequest? {
        try await snapshot(for: workspace)?.pullRequest
    }

    public static func pullRequest(forBranch branch: String, worktree: String) async throws -> PullRequest? {
        guard let project = await project(in: worktree) else { return nil }
        let candidates = try await mergeRequests(withSource: branch, in: project, worktree: worktree)
            .filter { $0.sourceProjectId == $0.targetProjectId }
        let chosen = candidates.first { $0.state == "opened" } ?? candidates.first
        guard let iid = chosen?.iid else { return nil }
        return try await snapshot(number: iid, in: project, worktree: worktree).pullRequest
    }

    public static func checks(for workspace: Workspace) async throws -> [CheckRun]? {
        try await snapshot(for: workspace)?.runs ?? []
    }

    public static func markReadyForReview(_ pullRequest: PullRequest, worktree: String) async throws {
        guard pullRequest.isOpen, pullRequest.isDraft else {
            throw GitHubError("This merge request is no longer an open draft.")
        }
        guard let project = await project(in: worktree) else { throw notAProject }
        try await check(["mr", "update", String(pullRequest.number), "--ready", "-R", project.webURL], cwd: worktree)
    }

    public static func checkRunLog(_ target: CheckFailureHandoff.LogTarget, worktree: String) async throws -> String {
        guard let jobID = target.jobID, let projectPath = target.project else {
            throw GitHubError("Bloom could not tell which GitLab job this is.")
        }
        guard let project = await project(in: worktree) else { throw notAProject }
        let jobProject = GitLabProject(remote: "https://\(project.host)/\(projectPath)") ?? project
        let result = try await run(
            api(project.host, "projects/\(jobProject.apiID)/jobs/\(jobID)/trace"), cwd: worktree, timeout: logTimeout
        )
        guard result.ok, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubError(result.stderr.isEmpty ? "glab returned no log for this job" : result.stderr)
        }
        return result.stdout
    }

    public static func openPullRequests(repoPath: String) async throws -> [PullRequestListing] {
        guard let project = await project(in: repoPath) else { return [] }
        let result = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests?state=opened&per_page=\(listLimit)"),
            cwd: repoPath
        )
        let listings = try GitLabDecoding.mergeRequests(from: Data(result.stdout.utf8)).map(GitLabDecoding.listing)
        return WorkspaceCheckoutPlan.offered(listings)
    }

    public static func pullRequestSummary(number: Int, repoPath: String) async throws -> PullRequestListing {
        guard number > 0 else { throw GitHubError("\(number) is not a merge request number") }
        guard let project = await project(in: repoPath) else { throw notAProject }
        let result = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests/\(number)"), cwd: repoPath
        )
        return GitLabDecoding.listing(try GitLabDecoding.mergeRequest(from: Data(result.stdout.utf8)))
    }

    public static func repositorySlug(repoPath: String) async -> String? {
        await project(in: repoPath)?.path
    }

    public static func checkoutPullRequest(number: Int, into worktree: String, localBranch: String) async throws {
        guard number > 0 else { throw GitHubError("\(number) is not a merge request number") }
        guard Git.isValidBranchName(localBranch) else {
            throw GitHubError("'\(localBranch)' is not a valid branch name")
        }
        guard let project = await project(in: worktree) else { throw notAProject }
        try await check(
            ["mr", "checkout", String(number), "--branch", localBranch, "-R", project.webURL],
            cwd: worktree, timeout: checkoutTimeout
        )
    }

    // MARK: Reading one merge request

    struct Snapshot {
        let pullRequest: PullRequest
        let runs: [CheckRun]
    }

    /// The newest merge request from the workspace's head that had not ended before it existed.
    /// GitLab filters on the recorded source branch, so this survives the branch being deleted.
    static func snapshot(for workspace: Workspace) async throws -> Snapshot? {
        guard let project = await project(in: workspace.path) else { return nil }
        let head = await GitHub.headBranch(of: workspace)
        let checkedOut = await checkedOutMergeRequest(branch: head, worktree: workspace.path)
        let candidates = try await mergeRequests(withSource: head, in: project, worktree: workspace.path)
        // A fork's merge request with the same branch name is somebody else's, unless this
        // worktree was checked out from it.
        let matches = candidates.compactMap { candidate -> PullRequestHeadMatch? in
            guard let iid = candidate.iid,
                  candidate.sourceProjectId == candidate.targetProjectId || iid == checkedOut
            else { return nil }
            let ended = GitLabDecoding.pullRequest(candidate, runs: []).closedAt
            return PullRequestHeadMatch(number: iid, closedAt: ended)
        }
        guard let chosen = PullRequestOwnership.choose(
            from: matches, startedAt: workspace.createdAt, checkedOutAs: checkedOut
        ) else { return nil }
        return try await snapshot(number: chosen, in: project, worktree: workspace.path)
    }

    private static func snapshot(number: Int, in project: GitLabProject, worktree: String) async throws -> Snapshot {
        let detail = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests/\(number)"), cwd: worktree
        )
        let payload = try GitLabDecoding.mergeRequest(from: Data(detail.stdout.utf8))
        guard let pipeline = payload.headPipeline else {
            return Snapshot(pullRequest: GitLabDecoding.pullRequest(payload, runs: []), runs: [])
        }
        let pipelineProject = pipeline.projectId.map(String.init) ?? project.apiID
        // An unreadable pipeline (a private fork) means unknown checks, not no merge request.
        guard let jobs = try? await check(
            api(project.host, "projects/\(pipelineProject)/pipelines/\(pipeline.id)/jobs?per_page=\(jobLimit)"),
            cwd: worktree
        ), let runs = try? GitLabDecoding.jobs(from: Data(jobs.stdout.utf8)) else {
            return Snapshot(pullRequest: GitLabDecoding.pullRequest(payload, runs: nil), runs: [])
        }
        return Snapshot(pullRequest: GitLabDecoding.pullRequest(payload, runs: runs), runs: runs)
    }

    private static func mergeRequests(
        withSource branch: String, in project: GitLabProject, worktree: String
    ) async throws -> [GitLabDecoding.MergeRequestPayload] {
        guard Git.isValidBranchName(branch) else { return [] }
        let query = "source_branch=\(queryValue(branch))&state=all&order_by=created_at&sort=desc"
            + "&per_page=\(candidateLimit)"
        let result = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests?\(query)"), cwd: worktree
        )
        return try GitLabDecoding.mergeRequests(from: Data(result.stdout.utf8))
    }

    /// The merge request `glab mr checkout` wrote into the branch's config, if it did.
    private static func checkedOutMergeRequest(branch: String, worktree: String) async -> Int? {
        guard Git.isValidBranchName(branch),
              let result = try? await Shell.run("git", ["config", "--get", "branch.\(branch).merge"], cwd: worktree),
              result.ok
        else { return nil }
        let reference = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "refs/merge-requests/"
        let suffix = "/head"
        guard reference.hasPrefix(prefix), reference.hasSuffix(suffix) else { return nil }
        return Int(reference.dropFirst(prefix.count).dropLast(suffix.count))
    }

    // MARK: Running glab

    /// The GitLab host this repository's base remote is on, for signing in to it.
    public static func host(in directory: String) async -> String? {
        await project(in: directory)?.host
    }

    static func project(in directory: String) async -> GitLabProject? {
        let context = try? await Git.repositoryContext(in: directory)
        return GitLabProject(remote: context?.baseRemoteURL)
    }

    private static let notAProject = GitHubError("This repository has no GitLab remote Bloom can read.")

    private static func api(_ host: String, _ endpoint: String) -> [String] {
        ["api", "--hostname", host, endpoint]
    }

    private static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    @discardableResult
    private static func check(
        _ arguments: [String], cwd: String?, timeout: Duration = readTimeout
    ) async throws -> ShellResult {
        let result = try await run(arguments, cwd: cwd, timeout: timeout)
        guard result.ok else {
            throw ShellError(
                command: "glab " + arguments.joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result
    }

    private static func run(
        _ arguments: [String], cwd: String?, timeout: Duration = readTimeout
    ) async throws -> ShellResult {
        if let commandOverride { return try await commandOverride(arguments, cwd) }
        return try await Shell.run("glab", arguments, cwd: cwd, timeout: timeout)
    }
}

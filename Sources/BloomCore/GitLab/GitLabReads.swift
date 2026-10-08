import Foundation

/// What GitLab reads can share: one read in flight per workspace, the last answer for a caller
/// that allows one, the jobs of a pipeline that has finished, which cannot change, and each
/// directory's project until its git config is written.
actor GitLabReads {
    static let shared = GitLabReads()
    /// Final until somebody retries a job, which moves the pipeline back to running and so misses.
    private static let finishedPipelines: Set<String> = ["success", "failed", "canceled", "skipped"]

    private var snapshots: [String: (snapshot: GitLab.Snapshot?, at: ContinuousClock.Instant)] = [:]
    private var flights: [String: Task<GitLab.Snapshot?, Error>] = [:]
    private var finishedJobs: [String: (status: String, runs: [CheckRun])] = [:]
    private var projects: [String: (configWritten: Date?, project: GitLabProject?)] = [:]

    func snapshot(
        for worktree: String, maxAge: Duration,
        read: @escaping @Sendable () async throws -> GitLab.Snapshot?
    ) async throws -> GitLab.Snapshot? {
        if maxAge > .zero, let entry = snapshots[worktree], entry.at.duration(to: .now) <= maxAge {
            return entry.snapshot
        }
        if let flight = flights[worktree] { return try await flight.value }
        let flight = Task { try await read() }
        flights[worktree] = flight
        defer { flights[worktree] = nil }
        let snapshot = try await flight.value
        snapshots[worktree] = (snapshot, .now)
        return snapshot
    }

    /// The jobs read when the pipeline last had this same final status.
    func jobs(of pipeline: String, status: String?) -> [CheckRun]? {
        guard let status, let entry = finishedJobs[pipeline], entry.status == status else { return nil }
        return entry.runs
    }

    func remember(_ runs: [CheckRun], of pipeline: String, status: String?) {
        guard let status, Self.finishedPipelines.contains(status) else {
            finishedJobs[pipeline] = nil
            return
        }
        finishedJobs[pipeline] = (status, runs)
    }

    func project(in directory: String, configWritten: Date?) -> GitLabProject?? {
        guard let entry = projects[directory], entry.configWritten == configWritten else { return nil }
        return .some(entry.project)
    }

    func store(_ project: GitLabProject?, in directory: String, configWritten: Date?) {
        projects[directory] = (configWritten, project)
    }
}

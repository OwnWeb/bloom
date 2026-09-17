import BloomCore
import BloomProtocol
import Foundation

/// The two parts of a summary that cost a subprocess to know: the branch's diff, and its pull
/// request. Measured on a slow schedule, and only while the machine is awake, since measuring a
/// sleeping machine would wake it.
///
/// Thirty seconds for the diff, matching how often a summary may carry it, and two minutes for the
/// pull request, which asks GitHub and changes when somebody opens or merges one rather than while
/// an agent types.
public actor WorktreeMeasurements {
    static let diffInterval: Duration = .seconds(30)
    static let pullRequestInterval: TimeInterval = 120

    private let runtime: WorkspaceRuntime
    private let reporter: MachineReporter
    private var loop: Task<Void, Never>?
    private var lastPullRequestCheck: Date?

    public init(runtime: WorkspaceRuntime, reporter: MachineReporter) {
        self.runtime = runtime
        self.reporter = reporter
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.measure()
                try? await Task.sleep(for: WorktreeMeasurements.diffInterval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    func measure() async {
        guard await reporter.awake, let workspace = try? await runtime.currentWorkspace(),
              FileManager.default.fileExists(atPath: workspace.path + "/.git") else { return }
        if let files = try? await RemoteReview.changes(workspace: workspace, scope: .branch) {
            await reporter.setDiff(RemoteSummary.Diff(
                files: files.count, additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions }
            ))
        }
        let now = Date()
        guard lastPullRequestCheck.map({ now.timeIntervalSince($0) >= Self.pullRequestInterval }) ?? true else { return }
        lastPullRequestCheck = now
        if let pull = try? await GitHub.pullRequest(forBranch: workspace.branch, worktree: workspace.path) {
            await reporter.setPullRequest(RemoteSummary.PullRequest(number: pull.number, url: pull.url, title: pull.title, state: pull.state.lowercased()))
        } else {
            await reporter.setPullRequest(nil)
        }
    }
}

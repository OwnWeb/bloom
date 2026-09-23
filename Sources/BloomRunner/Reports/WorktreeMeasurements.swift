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
///
/// **And at the three moments the diff is known to have moved: setup finishing, a turn ending, and
/// the machine letting go of its hold.** A schedule alone was wrong on a new workspace: its first
/// reading ran before the clone existed, the machine slept before the second, and runbloom.app was
/// told the branch had no files on it for as long as it slept. The Mac draws "Nothing has changed
/// on this branch yet" and no Create pull request button from that number, over a branch the agent
/// had just written to. See `activity(_:)` and `AwakeController.beforeSleeping(_:)`.
public actor WorktreeMeasurements {
    static let diffInterval: Duration = .seconds(30)
    static let pullRequestInterval: TimeInterval = 120

    private let runtime: WorkspaceRuntime
    private let reporter: MachineReporter
    private var loop: Task<Void, Never>?
    private var lastPullRequestCheck: Date?
    /// The reading in progress, which the next waits behind: two readings interleaved could land
    /// in either order, and the older one landing last would put a stale diff in the summary.
    private var measuring: Task<Void, Never>?

    public init(runtime: WorkspaceRuntime, reporter: MachineReporter) {
        self.runtime = runtime
        self.reporter = reporter
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.measureIfAwake()
                try? await Task.sleep(for: WorktreeMeasurements.diffInterval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The schedule's reading, which a machine that is not holding itself awake goes without.
    func measureIfAwake() async {
        guard await reporter.awake else { return }
        await measureNow()
    }

    /// Something the runtime reported. Setup finishing is when there is first a branch to measure
    /// and a turn ending is when an agent has just written to it, so both are measured at once
    /// rather than whenever the schedule next comes round, which a sleeping machine never reaches.
    public func activity(_ event: RemoteActivityEvent) async {
        switch event {
        case .setupFinished, .turnFinished: await measureNow()
        default: return
        }
    }

    /// Measures now, awake or not. Whatever calls this is running, so the machine is awake whatever
    /// the hold says, and the reading is wanted before it is let go.
    public func measureNow() async {
        let previous = measuring
        let reading = Task {
            await previous?.value
            await self.read()
        }
        measuring = reading
        await reading.value
    }

    private func read() async {
        // Not until the clone has finished: a checkout being written reads as every tracked file
        // deleted, which is the one answer worse than none. See `RemoteReviewCache.isWorktreeCloned`.
        guard await runtime.isWorktreeCloned, let workspace = try? await runtime.currentWorkspace(),
              FileManager.default.fileExists(atPath: workspace.path + "/.git") else { return }
        if let files = try? await RemoteReview.changes(workspace: workspace, scope: .branch) {
            await reporter.setDiff(RemoteSummary.Diff(
                files: files.count, additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions }
            ))
        }
        // Two git calls, on the same slow schedule as the diff, and nil rather than zeroes when
        // git cannot be asked. The archive confirmation reads these to say how much is at stake.
        await reporter.setAtStake(await RemoteWorkAtStake.measure(workspace: workspace))
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

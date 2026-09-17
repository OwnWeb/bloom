import BloomCore
import BloomProtocol
import Foundation

/// Summaries and usage reports, built from the runtime and the machine and handed to delivery.
///
/// **A summary goes when something a person would want to see changed, and not otherwise.** Each
/// candidate is compared with the last one sent, ignoring its revision and time, so a server that
/// is asked to post twice for one change posts once. The rates are `RemoteSummarySchedule`'s.
///
/// **The revision survives restarts.** runbloom.app ignores a summary whose revision is not newer
/// than the one it holds, so a server that started counting from one again after an update would
/// be ignored until it caught up. The revision is the larger of the stored one plus one and the
/// time in milliseconds, which is monotonic across restarts, updates and cold wakes alike.
public actor MachineReporter {
    private let runtime: WorkspaceRuntime
    private let store: Store
    private let delivery: ReportDelivery
    private let host: any MachineHost
    private let version: String
    private let now: @Sendable () -> Date

    private var schedule = RemoteSummarySchedule()
    private var lastSent: RemoteSummary?
    private var pending: Task<Void, Never>?
    private var pendingIncludesSlow = false
    private var meter: RemoteUsageMeter?
    private var diff = RemoteSummary.Diff(files: 0, additions: 0, deletions: 0)
    private var pullRequest: RemoteSummary.PullRequest?
    private(set) var awake = false
    private(set) var leaseUntil: Date?

    static let revisionKey = "remote.summary.revision"
    static let meterKey = "remote.usage.meter"

    public init(runtime: WorkspaceRuntime, store: Store, delivery: ReportDelivery, host: any MachineHost, version: String,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.runtime = runtime
        self.store = store
        self.delivery = delivery
        self.host = host
        self.version = version
        self.now = now
    }

    // MARK: - Summaries

    /// Something changed. `slow` is the diff or presence, which go at most every thirty seconds.
    public func changed(slow: Bool = false) {
        let change: RemoteSummarySchedule.Change = slow ? .slow : .prompt
        let due = schedule.due(for: change, now: now())
        if slow { pendingIncludesSlow = true }
        guard pending == nil else { return }
        let wait = max(0, due.timeIntervalSince(now()))
        pending = Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            await self.postSummary()
        }
    }

    public func setAwake(_ awake: Bool, leaseUntil: Date?) {
        let moved = self.awake != awake || self.leaseUntil != leaseUntil
        self.awake = awake
        self.leaseUntil = leaseUntil
        if moved { changed() }
    }

    public func setDiff(_ diff: RemoteSummary.Diff) {
        guard diff != self.diff else { return }
        self.diff = diff
        changed(slow: true)
    }

    public func setPullRequest(_ pullRequest: RemoteSummary.PullRequest?) {
        guard pullRequest != self.pullRequest else { return }
        self.pullRequest = pullRequest
        changed()
    }

    /// Posts now, whatever the schedule says: the first summary before setup, and the last one
    /// before the machine sleeps.
    public func postSummaryNow() async {
        pending?.cancel()
        pending = nil
        await postSummary()
    }

    private func postSummary() async {
        pending = nil
        let includesSlow = pendingIncludesSlow
        pendingIncludesSlow = false
        do {
            let revision = try await nextRevision()
            let summary = try await runtime.summary(revision: revision, observedAt: now(), version: version, awake: awake,
                                                    leaseUntil: leaseUntil, diff: diff, pullRequest: pullRequest)
            guard summary.content != lastSent?.content else { return }
            await delivery.submitSummary(try WireJSON.encode(summary))
            lastSent = summary
            schedule.posted(at: now(), includedSlowChanges: includesSlow)
        } catch {
            // The workspace row is gone or unreadable, which only happens mid-archive. The next
            // change tries again.
        }
    }

    private func nextRevision() async throws -> Int64 {
        let stored = Int64(try await store.setting(Self.revisionKey) ?? "") ?? 0
        let revision = max(stored + 1, Int64(now().timeIntervalSince1970 * 1_000))
        try await store.setSetting(Self.revisionKey, String(revision))
        return revision
    }

    // MARK: - Usage

    public func record(_ event: UsageEvent) async {
        var meter = await loadMeter()
        meter.record(event)
        await save(meter)
    }

    /// Takes a reading. Answers whether the machine was paused since the last one.
    public func sample(awake: Bool) async -> Bool {
        guard let reading = host.usageSample() else { return false }
        var meter = await loadMeter()
        let paused = meter.sample(reading, at: now(), awake: awake)
        await save(meter)
        return paused
    }

    public func sendUsage(includingDisk: Bool) async {
        var meter = await loadMeter()
        let report = meter.report(at: now(), includingDisk: includingDisk)
        await save(meter)
        if let data = try? WireJSON.encode(report) { await delivery.submitUsage(data) }
    }

    /// Waits for what is queued to reach runbloom.app, for at most this long.
    public func flush(timeout: Duration) async -> Bool {
        await delivery.flush(timeout: timeout)
    }

    private func loadMeter() async -> RemoteUsageMeter {
        if let meter { return meter }
        if let text = try? await store.setting(Self.meterKey),
           let stored = try? WireJSON.decode(RemoteUsageMeter.self, from: Data(text.utf8)) {
            meter = stored
            return stored
        }
        let fresh = RemoteUsageMeter(bootID: host.usageSample()?.bootID ?? "unknown")
        meter = fresh
        return fresh
    }

    private func save(_ meter: RemoteUsageMeter) async {
        self.meter = meter
        if let data = try? WireJSON.encode(meter) {
            try? await store.setSetting(Self.meterKey, String(decoding: data, as: UTF8.self))
        }
    }
}

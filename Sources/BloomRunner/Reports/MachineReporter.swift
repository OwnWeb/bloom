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
    private let capabilities: @Sendable () -> [String]
    private let now: @Sendable () -> Date

    private var schedule = RemoteSummarySchedule()
    private var lastSent: RemoteSummary?
    private var pending: Task<Void, Never>?
    /// The post running now, which the next one waits behind.
    private var posting: Task<Void, Never>?
    private var pendingIncludesSlow = false
    private var meter: RemoteUsageMeter?
    private(set) var diff = RemoteSummary.Diff(files: 0, additions: 0, deletions: 0)
    private var pullRequest: RemoteSummary.PullRequest?
    /// Nil until something measures it, and nil again when it cannot be measured: the summary
    /// leaves the fields out rather than sending zeroes.
    private var atStake: RemoteWorkAtStake?
    /// The shed count already told to runbloom.app, so one hole is reported once.
    private var reportedShed = 0
    private(set) var awake = false
    private(set) var leaseUntil: Date?
    /// What the machine could do while it was serving, taken when it began to stop. See
    /// `windingDown()`.
    private var capabilitiesWhileServing: [String]?

    static let revisionKey = "remote.summary.revision"
    static let meterKey = "remote.usage.meter"

    public init(runtime: WorkspaceRuntime, store: Store, delivery: ReportDelivery, host: any MachineHost, version: String,
                capabilities: [String] = [],
                capabilitiesProvider: (@Sendable () -> [String])? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.runtime = runtime
        self.store = store
        self.delivery = delivery
        self.host = host
        self.version = version
        self.capabilities = capabilitiesProvider ?? { capabilities }
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
            // `postSummaryNow` cancelled this and posted itself.
            guard !Task.isCancelled else { return }
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

    /// What would be lost if the machine went now. A measurement that failed is nil, not zeroes.
    public func setAtStake(_ measured: RemoteWorkAtStake?) {
        guard measured != atStake else { return }
        atStake = measured
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

    /// Posts now and waits, for at most `timeout`, for it to reach runbloom.app. Answers whether it
    /// did. For the first summary after a start, which has to land before the restored queue asks
    /// for a turn: see `ServeCommand`.
    public func postSummaryAndWait(timeout: Duration) async -> Bool {
        await postSummaryNow()
        return await delivery.flush(timeout: timeout)
    }

    /// The machine has begun to stop. Every summary from here on carries the capabilities it had
    /// while it served, rather than what is left of them as the wind down takes things apart.
    ///
    /// **runbloom.app reads a capability that goes missing as one that was lost, and acts on it.**
    /// The model gateway is stopped before the last summary is posted, so that summary used to
    /// leave `opaque_model_grants_v1` out, and runbloom.app answered by revoking the machine's
    /// model grants. A restart with a prompt queued then had its turn refused with 403
    /// `model_grant_invalid` and the chat's queue paused. Stopping is not losing: the next process
    /// says for itself what it can do. A failure while serving still takes a capability away,
    /// because this is taken only once the wind down begins.
    public func windingDown() {
        guard capabilitiesWhileServing == nil else { return }
        capabilitiesWhileServing = capabilities()
    }

    /// One at a time, in order. Two overlapping posts each read `awake` before suspending, and the
    /// one that read it first could land last: runbloom.app's last word was a machine awake that
    /// had just been released. Each post reads the state when its turn comes, so the later one
    /// always carries the later state.
    private func postSummary() async {
        pending = nil
        let previous = posting
        let post = Task {
            await previous?.value
            await self.postOnce()
        }
        posting = post
        await post.value
    }

    private func postOnce() async {
        let includesSlow = pendingIncludesSlow
        pendingIncludesSlow = false
        do {
            let revision = try await nextRevision()
            let summary = try await runtime.summary(revision: revision, observedAt: now(), version: version,
                                                    capabilities: capabilitiesWhileServing ?? capabilities(), awake: awake,
                                                    leaseUntil: leaseUntil, diff: diff, pullRequest: pullRequest, atStake: atStake)
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

    /// Every change to the meter happens with no suspension between reading it and writing it back,
    /// because a release and a shutdown can overlap, and a meter read before one of them suspended
    /// and written back after it overwrote the other's events: the report that said `released`
    /// went missing. The database copy is written afterwards and only survives restarts.
    public func record(_ event: UsageEvent) async {
        await loadMeterOnce()
        meter?.record(event)
        await persistMeter()
    }

    /// Takes a reading. Answers whether the machine was paused since the last one.
    public func sample(awake: Bool) async -> Bool {
        guard let reading = host.usageSample() else { return false }
        await loadMeterOnce()
        let paused = meter?.sample(reading, at: now(), awake: awake) ?? false
        await persistMeter()
        return paused
    }

    public func sendUsage(includingDisk: Bool) async {
        await loadMeterOnce()
        // Reports thrown away for want of anywhere to put them, told to runbloom.app as an event of
        // its own, so its account of this machine has a marked hole rather than a quiet one. The
        // count is cumulative, so a `reports_shed` that is itself shed is covered by the next.
        let shed = await delivery.status.shed
        if shed > reportedShed {
            reportedShed = shed
            meter?.record(.reportsShed(shed, at: now()))
        }
        // Several reports in a row when more events are waiting than one report may carry, taken
        // with no suspension between, so a record cannot land between two of them out of order.
        var reports: [UsageReport] = []
        repeat {
            guard let report = meter?.report(at: now(), includingDisk: includingDisk && reports.isEmpty) else { break }
            reports.append(report)
        } while meter?.hasUnreportedEvents == true
        for report in reports {
            if let data = try? WireJSON.encode(report) { await delivery.submitUsage(data) }
        }
        await persistMeter()
    }

    /// Waits for what is queued to reach runbloom.app, for at most this long.
    public func flush(timeout: Duration) async -> Bool {
        await delivery.flush(timeout: timeout)
    }

    private func loadMeterOnce() async {
        guard meter == nil else { return }
        var loaded: RemoteUsageMeter?
        if let text = try? await store.setting(Self.meterKey) {
            loaded = try? WireJSON.decode(RemoteUsageMeter.self, from: Data(text.utf8))
        }
        // Another caller may have loaded it while this one read the database; theirs is newer.
        guard meter == nil else { return }
        meter = loaded ?? RemoteUsageMeter(bootID: host.usageSample()?.bootID ?? "unknown")
    }

    private func persistMeter() async {
        guard let meter, let data = try? WireJSON.encode(meter) else { return }
        try? await store.setSetting(Self.meterKey, String(decoding: data, as: UTF8.self))
    }
}

import BloomCore
import Foundation

/// Holds the machine awake while `RemoteAwakePolicy` says there is a reason, and lets it sleep in
/// the one order that loses nothing when there is not.
///
/// **The order of letting go is forced by a measurement.** A Sprite released from its last task
/// paused almost at once, not thirty seconds later, so anything sent after the release may freeze
/// in the middle of the request. So: the final summary with `awake: false` and the usage report go
/// first and are waited for; then every stream is told `sleeping` and closed; and only then is the
/// hold deleted. See docs/REMOTE-WORKSPACES.md, "Awake, asleep, and what it costs".
///
/// **A pause is noticed afterwards, as a gap.** A paused machine's timers do not fire, so the
/// usage sampler sees fifteen seconds become ten minutes. That is when a limit that lifted while
/// it slept is tried again, which is the fallback the design promises for a `limits-cleared` call
/// that never arrived.
public actor AwakeController {
    /// How long each hold asks for. Short, so a server that died holding one frees the machine
    /// within minutes; renewed well before it runs out.
    static let holdLength: Duration = .seconds(300)
    static let renewAfter: TimeInterval = 120
    static let evaluateInterval: Duration = .seconds(5)
    static let usageReportInterval: TimeInterval = 300
    static let releaseFlushTimeout: Duration = .seconds(10)

    private let host: any MachineHost
    private let runtime: WorkspaceRuntime
    private let reporter: MachineReporter
    private let now: @Sendable () -> Date

    private(set) var holding = false
    private var lastRenewal: Date?
    private var lastUsageReport: Date?
    private var lastSample: Date?
    private var lastStreamClosedAt: Date?
    private var openStreams = 0
    private var loop: Task<Void, Never>?
    private var releasing = false

    public init(host: any MachineHost, runtime: WorkspaceRuntime, reporter: MachineReporter, now: @escaping @Sendable () -> Date = Date.init) {
        self.host = host
        self.runtime = runtime
        self.reporter = reporter
        self.now = now
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: AwakeController.evaluateInterval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The number of open event streams moved. Their closing is what shortens the presence lease.
    public func connectionsChanged(open: Int) async {
        if open == 0, openStreams > 0 { lastStreamClosedAt = now() }
        openStreams = open
        await evaluate()
    }

    /// Something happened that may change the answer: ask now rather than at the next tick.
    public func nudge() async {
        await evaluate()
    }

    func tick() async {
        let date = now()
        if lastSample.map({ date.timeIntervalSince($0) >= RemoteUsageMeter.sampleInterval }) ?? true {
            lastSample = date
            if await reporter.sample(awake: holding) {
                // The machine slept since the last reading. Whatever was refused for a limit gets
                // another chance now that something woke it.
                await runtime.limitsCleared()
            }
        }
        if holding, lastUsageReport.map({ date.timeIntervalSince($0) >= Self.usageReportInterval }) ?? true {
            lastUsageReport = date
            await reporter.sendUsage(includingDisk: false)
        }
        await evaluate()
    }

    func evaluate() async {
        guard !releasing else { return }
        let activity = await runtime.activity()
        let situation = RemoteAwakePolicy.Situation(
            setupRunning: activity.setupRunning, turnsRunning: activity.turnsRunning,
            questionWaitingSince: activity.questionWaitingSince, lastHumanInputAt: activity.lastHumanInputAt,
            openStreams: openStreams, lastStreamClosedAt: lastStreamClosedAt
        )
        let decision = RemoteAwakePolicy.decide(situation, now: now())
        if decision.holds {
            await hold(reason: decision.reasons[0], leaseUntil: decision.leaseUntil)
        } else if holding {
            await release()
        }
    }

    private func hold(reason: RemoteAwakePolicy.Reason, leaseUntil: Date?) async {
        let date = now()
        if !holding {
            do {
                try await host.hold(for: Self.holdLength)
            } catch {
                return
            }
            holding = true
            lastRenewal = date
            lastUsageReport = date
            await reporter.record(.awake(reason, at: date))
            await reporter.setAwake(true, leaseUntil: leaseUntil)
            return
        }
        await reporter.setAwake(true, leaseUntil: leaseUntil)
        if lastRenewal.map({ date.timeIntervalSince($0) >= Self.renewAfter }) ?? true {
            if (try? await host.hold(for: Self.holdLength)) != nil { lastRenewal = date }
        }
    }

    /// Everything that must reach anybody goes first, then the streams close, then the hold goes.
    func release() async {
        releasing = true
        defer { releasing = false }
        let date = now()
        await reporter.record(.released(at: date))
        await reporter.setAwake(false, leaseUntil: nil)
        await reporter.postSummaryNow()
        await reporter.sendUsage(includingDisk: true)
        _ = await reporter.flush(timeout: Self.releaseFlushTimeout)
        await runtime.announceSleep()
        if (try? await host.release()) != nil {
            holding = false
            lastRenewal = nil
        }
    }

    /// Shutting down: the same order as a release, whether or not anything was held.
    public func shutdown() async {
        stop()
        await reporter.record(.released(at: now()))
        await reporter.setAwake(false, leaseUntil: nil)
        await reporter.postSummaryNow()
        await reporter.sendUsage(includingDisk: true)
        _ = await reporter.flush(timeout: Self.releaseFlushTimeout)
        try? await host.release()
        holding = false
    }
}

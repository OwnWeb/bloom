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

    /// Where the machine is in holding itself awake. One value rather than four flags, because the
    /// flags could say two things at once: holding and shut down, releasing with `released` still
    /// owed. Every transition below reads and writes this and nothing else.
    enum Phase: Equatable {
        /// No hold, and nothing owed to runbloom.app.
        case asleep
        /// A hold is taken, `awake` is recorded, and a `released` is owed.
        case awake
        /// `released` is recorded and the last reports are going out; the hold is still held.
        case releasing
        /// Final. Nothing is held after this and no report is sent.
        case shutDown
    }

    private(set) var phase: Phase = .asleep
    var holding: Bool { phase == .awake || phase == .releasing }
    private var lastRenewal: Date?
    private var lastUsageReport: Date?
    private var lastSample: Date?
    private var lastStreamClosedAt: Date?
    private var openStreams = 0
    private var loop: Task<Void, Never>?
    private var onWake: @Sendable () async -> Void = {}
    private var onSleep: @Sendable () async -> Void = {}

    public init(host: any MachineHost, runtime: WorkspaceRuntime, reporter: MachineReporter, now: @escaping @Sendable () -> Date = Date.init) {
        self.host = host
        self.runtime = runtime
        self.reporter = reporter
        self.now = now
    }

    /// What else a wake should do. runbloom.app sends changed environment only to awake machines, so
    /// a machine that slept through a change fetches it again here.
    public func whenWaking(_ action: @escaping @Sendable () async -> Void) {
        onWake = action
    }

    /// What has to be measured before the last summary goes, run while the hold is still held.
    ///
    /// **The summary a machine sleeps on is what runbloom.app shows until it wakes**, and the diff
    /// in it was whatever the thirty second schedule last read. A new workspace's first reading was
    /// taken before its clone existed and the machine slept before the second, so its summary said
    /// no files had changed for as long as it slept, over a branch the agent had written to.
    public func beforeSleeping(_ action: @escaping @Sendable () async -> Void) {
        onSleep = action
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
        // A tick that was already running when shutdown began must not send a report after the
        // final one, which would leave runbloom.app's last word from this boot without `released`.
        guard loop != nil, phase != .releasing, phase != .shutDown else { return }
        let date = now()
        if lastSample.map({ date.timeIntervalSince($0) >= RemoteUsageMeter.sampleInterval }) ?? true {
            lastSample = date
            if await reporter.sample(awake: holding) {
                // The machine slept since the last reading. Whatever was refused for a limit gets
                // another chance now that something woke it.
                await runtime.limitsCleared()
                await onWake()
            }
        }
        guard loop != nil else { return }
        if phase == .awake, lastUsageReport.map({ date.timeIntervalSince($0) >= Self.usageReportInterval }) ?? true {
            lastUsageReport = date
            await reporter.sendUsage(includingDisk: false)
        }
        await evaluate()
    }

    func evaluate() async {
        guard phase == .asleep || phase == .awake else { return }
        let decision = await decide()
        guard phase == .asleep || phase == .awake else { return }
        if decision.holds {
            await hold(reason: decision.reasons[0], leaseUntil: decision.leaseUntil)
        } else if phase == .awake {
            await release()
        }
    }

    private func decide() async -> RemoteAwakePolicy.Decision {
        let activity = await runtime.activity()
        let situation = RemoteAwakePolicy.Situation(
            setupRunning: activity.setupRunning, turnsRunning: activity.turnsRunning,
            questionWaitingSince: activity.questionWaitingSince, lastHumanInputAt: activity.lastHumanInputAt,
            openStreams: openStreams, lastStreamClosedAt: lastStreamClosedAt
        )
        return RemoteAwakePolicy.decide(situation, now: now())
    }

    private func hold(reason: RemoteAwakePolicy.Reason, leaseUntil: Date?) async {
        let date = now()
        if phase == .asleep {
            do {
                try await host.hold(for: Self.holdLength)
            } catch {
                return
            }
            // Shutdown began while the hold was being made. Its final report already went out, so
            // this hold is let go again rather than outliving the process.
            guard phase == .asleep else {
                if phase == .shutDown { try? await host.release() }
                return
            }
            phase = .awake
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
        guard phase == .awake else { return }
        // `released` once per hold: runbloom.app adds its margin per `released`, and a second one
        // for the same pause would bill it twice. Leaving `.awake` is what records it.
        phase = .releasing
        // First, and while the hold is still held, so what it measures is in the summary below.
        await onSleep()
        await reporter.record(.released(at: now()))
        await reporter.setAwake(false, leaseUntil: nil)
        await reporter.postSummaryNow()
        await reporter.sendUsage(includingDisk: true)
        _ = await reporter.flush(timeout: Self.releaseFlushTimeout)
        // The flush can take seconds, and every nudge in them was dropped. A turn that started
        // meanwhile must not have the machine paused under it, so the answer is asked again
        // right before the hold goes.
        let second = await decide()
        if second.holds, phase == .releasing {
            phase = .awake
            lastUsageReport = now()
            await reporter.record(.awake(second.reasons[0], at: now()))
            await reporter.setAwake(true, leaseUntil: second.leaseUntil)
            return
        }
        await runtime.announceSleep()
        // Cleared even when the release fails: the hold runs out by itself within `holdLength`,
        // and a `holding` left true with `released` already reported would skip the next `awake`
        // and send this whole release again every tick.
        try? await host.release()
        if phase == .releasing { phase = .asleep }
        lastRenewal = nil
    }

    /// Shutting down: the same order as a release, whether or not anything was held.
    public func shutdown() async {
        stop()
        // A release in flight is sending the same reports; let it finish rather than interleave.
        while phase == .releasing {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Checked and set with no suspension between, so nothing can take a hold in the gap.
        let owed = phase == .awake
        phase = .shutDown
        if owed { await reporter.record(.released(at: now())) }
        await reporter.setAwake(false, leaseUntil: nil)
        await reporter.postSummaryNow()
        await reporter.sendUsage(includingDisk: true)
        _ = await reporter.flush(timeout: Self.releaseFlushTimeout)
        try? await host.release()
    }
}

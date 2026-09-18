import BloomCore
import BloomProtocol
import Foundation

/// Gets summaries and usage reports to runbloom.app, eventually, without anybody waiting on it.
///
/// The two are delivered differently because runbloom.app reads them differently. A summary is
/// replace-latest: runbloom.app keeps the highest revision, so an unsent summary that a newer one
/// has overtaken is worth nothing and is dropped. A usage report is append-only: its counters are
/// cumulative and runbloom.app takes differences between sequences, so every report goes, in the
/// order it was made, and a repeat is harmless. See docs/REMOTE-WORKSPACES.md, "Usage" and
/// "Summaries".
///
/// A failure that could clear (the network, a 5xx) backs off from one second to a minute and tries
/// again. A 4xx is runbloom.app's considered answer about that report and drops it, because
/// sending the same bytes again would get the same answer forever and hold every report behind it.
///
/// One worker at a time sends, so a report is never in flight twice and usage cannot overtake
/// itself.
///
/// **The backlog is capped, and it sheds the oldest.** An outage is bounded by nothing else here:
/// a machine held awake posts a usage report every five minutes for as long as the outage lasts,
/// and a queue that grew for a week would be a machine dying of its own reporting. The cap is in
/// bytes because memory is in bytes, and at the measured sizes (209 bytes for a quiet report, 2.5
/// kB for one carrying twenty turns, 145 kB for the largest runbloom.app will accept) four
/// megabytes is ten weeks of a quiet machine, six days of a busy one, and two and a half hours of
/// one reporting at the ceiling, which is far longer than any of them stays awake. Past that the
/// oldest goes, because the counters are cumulative and the newest report carries the totals:
/// what is lost is the account of which turns made up the oldest hours, never what the workspace
/// cost. `RemoteUsageMeter.record` already sheds its oldest events the same way and for the same
/// reason. Every shedding is counted, said to whoever is looking at the workspace, and told to
/// runbloom.app in a `reports_shed` event once it can be reached, so a hole is a known hole.
public actor ReportDelivery {
    /// Four megabytes of unsent usage. See the note above for what that is in days.
    public static let maximumQueuedBytes = 4 << 20

    /// How long failures have to keep failing before the machine says so, and how many there have
    /// to have been.
    ///
    /// **Because a paused machine is not an unreachable one.** A Sprite that goes idle is
    /// suspended, and a request in flight across a suspension fails exactly as a network outage
    /// does. It happened on 18 September 2026: a workspace went idle at 11:19:55, the machine said
    /// "runbloom.app unreachable" at 11:21:30, and the control server was answering perfectly well
    /// the whole time. Nothing was wrong except that a request died when its machine went to sleep,
    /// and the person watching would have been shown an alarming sentence about a workspace that
    /// was merely asleep.
    ///
    /// A suspended machine takes no further attempts, so the run of failures stops at one and the
    /// next attempt, after it wakes, succeeds. **Requiring a second failure and half a minute costs
    /// a real outage half a minute of silence**, which is nothing against the hours this record
    /// exists to describe, and it costs a sleeping machine nothing at all.
    static let outageBeforeSaying: TimeInterval = 30
    static let failuresBeforeSaying = 2

    /// What the machine can say about its own reporting, which is the one failure here that
    /// otherwise shows nowhere. Handed to whoever wants to publish or log it, on every change.
    public struct Status: Sendable, Hashable {
        public var unreachableSince: Date?
        public var queued: Int
        public var queuedBytes: Int
        public var shed: Int

        /// Nil while everything is in touch and nothing has been shed, which is the normal case
        /// and the one a client should draw nothing for.
        public var record: ReportingRecord? {
            guard unreachableSince != nil || shed > 0 else { return nil }
            return ReportingRecord(unreachableSince: unreachableSince, shed: shed)
        }
    }

    /// The two sends, as closures so the delivery rules are testable without HTTP.
    public struct Sender: Sendable {
        public var summary: @Sendable (Data) async throws -> Void
        public var usage: @Sendable (Data) async throws -> Void

        public init(summary: @escaping @Sendable (Data) async throws -> Void, usage: @escaping @Sendable (Data) async throws -> Void) {
            self.summary = summary
            self.usage = usage
        }

        public init(client: RunbloomClient) {
            self.init(summary: { try await client.postSummary($0) }, usage: { try await client.postUsage($0) })
        }
    }

    private let sender: Sender
    private let initialDelay: Duration
    private let maximumDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let observer: @Sendable (Status) async -> Void
    private let now: @Sendable () -> Date

    private var summary: Data?
    /// Bumped by every submitted summary, so a send that finishes after a newer one arrived clears
    /// nothing: the newer one is still owed.
    private var summaryRevision = 0
    private var usage: [Data] = []

    private var queuedBytes = 0
    /// When contact was lost, which is the moment of the last report that got through, or this
    /// server's start when none ever has. Set on the first failure worth retrying, cleared by the
    /// next success, so a flap of one report does not read as an outage that never ended.
    private var unreachableSince: Date?
    /// The first failure of the run of failures in hand, and how many there have been. **Not for
    /// measuring the outage**, which began at the last success; for deciding whether there is an
    /// outage to speak of at all. See `outageBeforeSaying`.
    private var firstFailureAt: Date?
    private var consecutiveFailures = 0
    private var lastReachedAt: Date
    private var shed = 0
    private var announced: Status?

    private var delay: Duration
    private var worker: Task<Void, Never>?
    private var pause: Task<Void, Never>?
    /// Set by `flush` so a worker between an attempt and its backoff goes straight round again.
    private var retryNow = false
    private var isShutDown = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(
        sender: Sender,
        initialDelay: Duration = .seconds(1),
        maximumDelay: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        observer: @escaping @Sendable (Status) async -> Void = { _ in }
    ) {
        self.sender = sender
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.sleep = sleep
        self.now = now
        self.observer = observer
        lastReachedAt = now()
        delay = initialDelay
    }

    public func submitSummary(_ body: Data) {
        guard !isShutDown else { return }
        summary = body
        summaryRevision += 1
        startWorker()
    }

    public func submitUsage(_ body: Data) {
        guard !isShutDown else { return }
        usage.append(body)
        queuedBytes += body.count
        // The oldest first, and only as many as the cap needs: a report is only ever whole, so
        // this sheds reports rather than trimming one.
        while queuedBytes > Self.maximumQueuedBytes, usage.count > 1 {
            queuedBytes -= usage.removeFirst().count
            shed += 1
        }
        startWorker()
    }

    /// What this has to say about itself, for a client and for the log.
    public var status: Status {
        Status(unreachableSince: outageWorthSaying, queued: usage.count + (summary == nil ? 0 : 1),
               queuedBytes: queuedBytes, shed: shed)
    }

    /// Whether anything is still owed to runbloom.app.
    public var hasPending: Bool { summary != nil || !usage.isEmpty }

    /// Before the machine sleeps or stops: cut any backoff short, try again at once, and wait at
    /// most `timeout` for everything to go. Answers whether it all did.
    public func flush(timeout: Duration) async -> Bool {
        guard hasPending else { return true }
        guard !isShutDown else { return false }
        retryNow = true
        pause?.cancel()
        startWorker()

        let id = UUID()
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resume(id, with: false)
        }
        let delivered = await withCheckedContinuation { waiters[id] = $0 }
        expiry.cancel()
        return delivered
    }

    /// Stops sending. Whatever is unsent stays unsent, and a flush still waiting answers now.
    public func shutdown() {
        isShutDown = true
        worker?.cancel()
        pause?.cancel()
        worker = nil
        let delivered = !hasPending
        for id in Array(waiters.keys) { resume(id, with: delivered) }
    }

    // MARK: - The worker

    private func startWorker() {
        guard worker == nil, !isShutDown, hasPending else { return }
        worker = Task { await self.run() }
    }

    private func run() async {
        while !isShutDown, !Task.isCancelled, hasPending {
            retryNow = false
            let failed = await attempt()
            guard failed, !isShutDown, !Task.isCancelled else {
                delay = initialDelay
                continue
            }
            if retryNow { continue }
            let wait = delay
            delay = min(delay * 2, maximumDelay)
            let sleep = self.sleep
            let pause = Task { _ = try? await sleep(wait) }
            self.pause = pause
            await pause.value
            self.pause = nil
        }
        worker = nil
        if !hasPending {
            for id in Array(waiters.keys) { resume(id, with: true) }
        }
    }

    /// One pass over everything owed. Answers whether something failed in a way worth retrying.
    private func attempt() async -> Bool {
        var failed = false

        if let body = summary {
            let revision = summaryRevision
            switch await outcome(of: { try await self.sender.summary(body) }) {
            case .delivered, .dropped:
                if summaryRevision == revision { summary = nil }
            case .retry:
                failed = true
            }
        }

        // In order, and stopping at the first that has to wait, so a later report never lands
        // before an earlier one.
        while let body = usage.first, !isShutDown {
            let result = await outcome(of: { try await self.sender.usage(body) })
            if result == .retry {
                failed = true
                break
            }
            if !usage.isEmpty { queuedBytes -= usage.removeFirst().count }
        }
        await announce()
        return failed
    }

    private enum Outcome { case delivered, dropped, retry }

    private func outcome(of send: @Sendable () async throws -> Void) async -> Outcome {
        do {
            try await send()
            reached()
            return .delivered
        } catch let error as RunbloomError where error.isTerminal {
            // The workspace is archived or its secret revoked: nothing this machine says will be
            // heard again, so it stops saying it rather than retrying for the rest of its life.
            // runbloom.app answered, so this is being reached: the silence is deliberate.
            reached()
            summary = nil
            usage.removeAll()
            queuedBytes = 0
            isShutDown = true
            return .dropped
        } catch let error as RunbloomError where !error.isWorthRetrying {
            reached()
            return .dropped
        } catch let error as RunbloomError where error.isBackpressure {
            // **Being asked to wait is not being unable to reach anybody.** runbloom.app answered,
            // and what it answered was "not now": the report is kept and tried again, and nothing
            // about the machine's ability to reach it is in doubt, so no outage is recorded.
            reached()
            return .retry
        } catch {
            // The first failure since the last success is when contact was lost, which is that
            // success, not now: an outage that began while nothing was being sent still began then.
            if unreachableSince == nil { unreachableSince = lastReachedAt }
            if firstFailureAt == nil { firstFailureAt = now() }
            consecutiveFailures += 1
            return .retry
        }
    }

    /// When contact was lost, but only once the losing has gone on long enough to mean something.
    /// The date is still the last success, because that is when reporting actually stopped; what
    /// this decides is whether to say it at all.
    private var outageWorthSaying: Date? {
        guard let unreachableSince, let firstFailureAt, consecutiveFailures >= Self.failuresBeforeSaying,
              now().timeIntervalSince(firstFailureAt) >= Self.outageBeforeSaying else { return nil }
        return unreachableSince
    }

    /// runbloom.app answered, whatever it said.
    private func reached() {
        lastReachedAt = now()
        unreachableSince = nil
        firstFailureAt = nil
        consecutiveFailures = 0
    }

    /// Tells the observer, once per change rather than once per attempt.
    private func announce() async {
        let current = status
        guard current != announced else { return }
        announced = current
        await observer(current)
    }

    private func resume(_ id: UUID, with delivered: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: delivered)
    }
}

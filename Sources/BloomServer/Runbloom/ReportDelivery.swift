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
public actor ReportDelivery {
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

    private var summary: Data?
    /// Bumped by every submitted summary, so a send that finishes after a newer one arrived clears
    /// nothing: the newer one is still owed.
    private var summaryRevision = 0
    private var usage: [Data] = []

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
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sender = sender
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.sleep = sleep
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
        startWorker()
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
            usage.removeFirst()
        }
        return failed
    }

    private enum Outcome { case delivered, dropped, retry }

    private func outcome(of send: @Sendable () async throws -> Void) async -> Outcome {
        do {
            try await send()
            return .delivered
        } catch let error as RunbloomError where error.isTerminal {
            // The workspace is archived or its secret revoked: nothing this machine says will be
            // heard again, so it stops saying it rather than retrying for the rest of its life.
            summary = nil
            usage.removeAll()
            isShutDown = true
            return .dropped
        } catch let error as RunbloomError where !error.isWorthRetrying {
            return .dropped
        } catch {
            return .retry
        }
    }

    private func resume(_ id: UUID, with delivered: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: delivered)
    }
}

import BloomCore
import Foundation

/// Sends the machine's word that somebody was addressed, and keeps sending it until it lands.
///
/// **Separate from `ReportDelivery` on purpose, because this causes mail.** That queue coalesces,
/// sheds its oldest under a cap and rides along with summaries; anything with those properties will
/// eventually send two emails or none. Here every row is sent on its own and retried until
/// runbloom.app takes it, which is safe because the other end dedupes on the id per addressed
/// person, so **a retry is free and a lost acknowledgement costs nothing**.
///
/// **The queue is the table**, not a list in memory: a machine that restarted between writing the
/// message and telling runbloom.app would otherwise never tell it, and the person would never be
/// mailed. So a run starts by draining whatever the last one left.
public actor AddressedReporter {
    private let store: Store
    private let send: @Sendable (Data) async throws -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var draining: Task<Void, Never>?
    private var isClosed = false

    /// Between attempts at a row that will not go. Slow, because the thing it is usually waiting
    /// for is an endpoint that does not exist yet or a server that is down, and neither is helped
    /// by asking faster.
    static let retryAfter = Duration.seconds(60)

    public init(
        store: Store,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        send: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.store = store
        self.send = send
        self.sleep = sleep
    }

    /// Drains what is waiting, including whatever an earlier run left behind.
    public func start() {
        guard draining == nil, !isClosed else { return }
        draining = Task { [weak self] in
            while let self, await !self.isShutDown {
                let again = await self.pass()
                guard again else { break }
                try? await self.wait()
            }
            await self?.finished()
        }
    }

    public func stop() {
        isClosed = true
        draining?.cancel()
        draining = nil
    }

    private var isShutDown: Bool { isClosed || Task.isCancelled }

    private func finished() { draining = nil }

    private func wait() async throws { try await sleep(Self.retryAfter) }

    /// One pass over the waiting rows. Answers whether anything is still waiting, which is the
    /// signal to come back rather than to stop.
    private func pass() async -> Bool {
        let waiting = (try? await store.unsentAddressedReports()) ?? []
        guard !waiting.isEmpty else { return false }
        var stillWaiting = false
        for report in waiting {
            guard !isShutDown else { return true }
            do {
                try await send(Data(report.body.compactJSON.utf8))
                try? await store.markAddressedReported(id: report.id)
            } catch {
                // Left where it is. The row is the queue, so nothing is lost by failing, and the
                // next pass tries the same id, which is what makes a retry free at the other end.
                stillWaiting = true
            }
        }
        return stillWaiting
    }
}

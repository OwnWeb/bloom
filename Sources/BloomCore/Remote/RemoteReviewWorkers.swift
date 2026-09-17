import Foundation

/// At most a few patch builds at once. A client opening every file of a large branch in a burst
/// would otherwise start one snapshot copy and one git process per file, all together.
///
/// A waiter that is cancelled leaves the queue at once rather than holding a place until a worker
/// frees up, so a closed connection cannot consume a slot it will never use.
actor RemoteReviewWorkers {
    private var used = 0
    private let maximum: Int
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(maximum: Int = 4) { self.maximum = max(1, maximum) }

    func acquire() async throws {
        try Task.checkCancellation()
        if used < maximum { used += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    func release() {
        if waiting.isEmpty { used -= 1 } else { waiting.removeFirst().1.resume() }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }

    var waitingCount: Int { waiting.count }
}

import BloomProtocol
import Foundation

/// Everyone with the workspace's event stream open, and the one door events reach them through.
///
/// **A client that cannot keep up is disconnected, never silently skipped.** Each subscriber has a
/// bounded buffer; the event that would overflow it ends that subscriber's stream instead of being
/// dropped, because a transcript with a hole in it looks complete and is not. The client reconnects
/// with its last cursor and is sent everything it missed, which is what the cursor is for.
public actor RemoteEventHub {
    public struct Subscription: Sendable {
        public let id: UUID
        public let events: AsyncStream<WorkspaceEvent>
    }

    private struct Subscriber {
        var userID: String?
        var continuation: AsyncStream<WorkspaceEvent>.Continuation
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private let bufferLimit: Int
    private let onChange: @Sendable () async -> Void

    /// `onChange` runs whenever a subscriber comes or goes, which is what presence counts.
    public init(bufferLimit: Int = 4_096, onChange: @escaping @Sendable () async -> Void = {}) {
        self.bufferLimit = bufferLimit
        self.onChange = onChange
    }

    public var count: Int { subscribers.count }

    public var connectedUserIDs: Set<String> { Set(subscribers.values.compactMap(\.userID)) }

    public func subscribe(userID: String?) async -> Subscription {
        let id = UUID()
        let (events, continuation) = AsyncStream.makeStream(of: WorkspaceEvent.self, bufferingPolicy: .bufferingOldest(bufferLimit))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        subscribers[id] = Subscriber(userID: userID, continuation: continuation)
        await onChange()
        return Subscription(id: id, events: events)
    }

    public func publish(_ event: WorkspaceEvent) {
        var overflowed: [UUID] = []
        for (id, subscriber) in subscribers {
            if case .dropped = subscriber.continuation.yield(event) { overflowed.append(id) }
        }
        for id in overflowed { subscribers.removeValue(forKey: id)?.continuation.finish() }
    }

    /// Sends one last event to some subscribers and closes their streams: everyone's when the
    /// machine is going to sleep, one person's when their access was revoked.
    public func close(with event: WorkspaceEvent, where matches: (String?) -> Bool = { _ in true }) async {
        let closing = subscribers.filter { matches($0.value.userID) }
        for (id, subscriber) in closing {
            subscriber.continuation.yield(event)
            subscriber.continuation.finish()
            subscribers.removeValue(forKey: id)
        }
        if !closing.isEmpty { await onChange() }
    }

    public func unsubscribe(_ id: UUID) async {
        subscribers.removeValue(forKey: id)?.continuation.finish()
        await onChange()
    }

    private func remove(_ id: UUID) async {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        await onChange()
    }
}

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
        /// What kind of client opened it, as it said: `mac` for Bloom on a Mac. Unverified, and it
        /// needs no verifying, because it only decides which of one person's own connections a
        /// message for their own Mac goes down. See `publish(_:toUser:client:)`.
        var client: String?
        var continuation: AsyncStream<WorkspaceEvent>.Continuation
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private let bufferLimit: Int
    private let onChange: @Sendable () async -> Void

    /// `onChange` runs whenever a subscriber comes or goes, which is what presence counts.
    public static let defaultBufferLimit = 4_096

    public init(bufferLimit: Int = defaultBufferLimit, onChange: @escaping @Sendable () async -> Void = {}) {
        self.bufferLimit = bufferLimit
        self.onChange = onChange
    }

    public var count: Int { subscribers.count }

    public var connectedUserIDs: Set<String> { Set(subscribers.values.compactMap(\.userID)) }

    public func subscribe(userID: String?, client: String? = nil) async -> Subscription {
        let id = UUID()
        let (events, continuation) = AsyncStream.makeStream(of: WorkspaceEvent.self, bufferingPolicy: .bufferingOldest(bufferLimit))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        subscribers[id] = Subscriber(userID: userID, client: client, continuation: continuation)
        await onChange()
        return Subscription(id: id, events: events)
    }

    public func publish(_ event: WorkspaceEvent) {
        var overflowed: [UUID] = []
        for (id, subscriber) in subscribers {
            if case .dropped = subscriber.continuation.yield(event) { overflowed.append(id) }
        }
        for id in overflowed { subscribers.removeValue(forKey: id)?.continuation.finish() }
        // Its termination handler finds nothing left to remove, so presence hears of it here.
        if !overflowed.isEmpty {
            let onChange = onChange
            Task { await onChange() }
        }
    }

    /// Sends one last event to some subscribers and closes their streams: everyone's when the
    /// machine is going to sleep, one person's when their access was revoked.
    /// `event` to one person's streams and nobody else's, answering how many there were. For what
    /// is theirs alone to see: a message for their own Mac. See `MacMessageRecord`.
    @discardableResult
    public func publish(_ event: WorkspaceEvent, toUser userID: String, client: String) -> Int {
        var told = 0
        for subscriber in subscribers.values where subscriber.userID == userID && subscriber.client == client {
            if case .enqueued = subscriber.continuation.yield(event) { told += 1 }
        }
        return told
    }

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

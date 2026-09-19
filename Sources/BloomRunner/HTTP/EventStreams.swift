import BloomCore
import BloomProtocol
import Foundation

/// Every open event stream, the token each one was opened or last refreshed with, and the means
/// to close one early.
///
/// **An open stream checks its token for as long as it is open, not only when it opens.** A
/// stream outlives the five minutes a token lives, so the client sends a fresh one on it before
/// the old one runs out (`POST /_bloom/v1/streams/{id}/token`), and a stream whose token runs out
/// first is closed with `token_expired`. Removing somebody from a team therefore takes effect
/// within five minutes by expiry alone, and at once when runbloom.app calls `revoke`.
public actor EventStreams {
    struct Entry {
        var userID: String?
        var expiresAt: Date
        var close: AsyncStream<WireError>.Continuation
    }

    private var entries: [String: Entry] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Registers a stream, and hands back its id and a stream that yields once when it has to close.
    /// **At most this many streams per person.** Several windows and devices, and a reconnect
    /// overlapping the stream it replaces, fit well inside it; a viewer opening streams in a loop
    /// and never reading does not (M3 in the review of 19 September 2026).
    static let perPersonLimit = 16

    func open(for token: WorkspaceToken) throws -> (id: String, closing: AsyncStream<WireError>) {
        let person = token.author?.userID
        guard entries.values.count(where: { $0.userID == person }) < Self.perPersonLimit else {
            throw RemoteFailure(.limitReached, "Too many event streams are open for you on this workspace. Close one and try again.")
        }
        let id = UUID().uuidString.lowercased()
        let (closing, continuation) = AsyncStream.makeStream(of: WireError.self, bufferingPolicy: .bufferingNewest(1))
        entries[id] = Entry(userID: token.author?.userID, expiresAt: token.expiresAt, close: continuation)
        let deadline = token.expiresAt
        Task { await self.expire(id, at: deadline) }
        return (id, closing)
    }

    /// A fresh token for an open stream. It has to be the same person's.
    func refresh(_ id: String, with token: WorkspaceToken) throws {
        guard var entry = entries[id] else { throw RemoteFailure(.notFound, "This event stream is no longer open.") }
        guard entry.userID == token.author?.userID else {
            throw RemoteFailure(.unauthenticated, "A stream can only be renewed with its own person's token.")
        }
        entry.expiresAt = max(entry.expiresAt, token.expiresAt)
        entries[id] = entry
        let deadline = entry.expiresAt
        Task { await self.expire(id, at: deadline) }
    }

    func closed(_ id: String) {
        entries.removeValue(forKey: id)?.close.finish()
    }

    /// Closes every stream a person holds, which is what revoking their access does.
    func revoke(userID: String) {
        for (id, entry) in entries where entry.userID == userID {
            entry.close.yield(WireError(.unauthenticated, "Your access to this Bloom Cloud workspace was removed."))
            entry.close.finish()
            entries.removeValue(forKey: id)
        }
    }

    var count: Int { entries.count }

    private func expire(_ id: String, at deadline: Date) async {
        let wait = deadline.timeIntervalSince(now())
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        // A refresh that landed meanwhile moved the deadline, and its own timer will close it.
        guard let entry = entries[id], entry.expiresAt <= now() else { return }
        entry.close.yield(WireError(.tokenExpired, "The session token for this stream expired. Reconnect with a fresh one."))
        entry.close.finish()
        entries.removeValue(forKey: id)
    }
}

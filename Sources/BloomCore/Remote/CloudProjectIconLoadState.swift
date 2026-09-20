/// Testable ownership and retry state for Cloud project artwork loads.
///
/// Image decoding stays in the Mac app, but the concurrency decision does not: only the current
/// ticket may land, transient failures wait for the normal Cloud poll before retrying, and team
/// plus project IDs form the authority boundary rather than a repository name.
public struct CloudProjectIconLoadState: Sendable {
    public struct Key: Hashable, Sendable {
        public var teamID: CloudTeamID
        public var projectID: CloudProjectID

        public init(teamID: CloudTeamID, projectID: CloudProjectID) {
            self.teamID = teamID
            self.projectID = projectID
        }
    }

    public struct Ticket: Hashable, Sendable {
        public var key: Key
        public var url: String
        fileprivate var generation: UInt64
    }

    public enum Completion: Sendable {
        case artwork
        case permanentFallback
        case transientFailure
    }

    public enum Status: Equatable, Sendable {
        case absent
        case loading
        case artwork
        case fallback
        case retryable
    }

    private struct Entry: Sendable {
        var ticket: Ticket
        var status: Status
    }

    private var entries: [Key: Entry] = [:]
    private var retryRevisions: [Key: Int] = [:]
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin(key: Key, url: String) -> Ticket {
        generation &+= 1
        let ticket = Ticket(key: key, url: url, generation: generation)
        entries[key] = Entry(ticket: ticket, status: .loading)
        return ticket
    }

    /// True only while this exact team, project, URL and generation still owns the cache slot.
    public func accepts(_ ticket: Ticket) -> Bool {
        entries[ticket.key]?.ticket == ticket
    }

    /// Lands a result only if no replacement or reset superseded it.
    @discardableResult
    public mutating func finish(_ ticket: Ticket, as completion: Completion) -> Bool {
        guard accepts(ticket) else { return false }
        let status: Status = switch completion {
        case .artwork: .artwork
        case .permanentFallback: .fallback
        case .transientFailure: .retryable
        }
        entries[ticket.key] = Entry(ticket: ticket, status: status)
        return true
    }

    /// Opens one retry on the ordinary Cloud poll. Permanent fallback never retries for the same
    /// immutable revision URL.
    @discardableResult
    public mutating func retryTransient(key: Key, url: String) -> Bool {
        guard let entry = entries[key], entry.ticket.url == url, entry.status == .retryable else { return false }
        entries.removeValue(forKey: key)
        retryRevisions[key, default: 0] += 1
        return true
    }

    public func status(for key: Key, url: String) -> Status {
        guard let entry = entries[key], entry.ticket.url == url else { return .absent }
        return entry.status
    }

    public func retryRevision(for key: Key) -> Int {
        retryRevisions[key, default: 0]
    }

    public mutating func clear(_ key: Key) {
        entries.removeValue(forKey: key)
    }

    public mutating func reset() {
        entries.removeAll()
        retryRevisions.removeAll()
    }
}

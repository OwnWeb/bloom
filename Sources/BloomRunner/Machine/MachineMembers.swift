import BloomCore
import Foundation

/// Who has access to this workspace, held between asks.
///
/// **A miss refetches, and that is the whole design.** A machine holding a list from three weeks
/// ago refuses a colleague who joined last week, which is the failure the refusal exists to prevent
/// wearing a slower disguise. So an id this does not recognise is a reason to ask runbloom.app
/// again, not a reason to answer "not a member".
///
/// **With a cooldown, because a mistyped handle is a miss too.** Somebody typing `@sebbb` produces
/// a miss per keystroke, and without a floor between asks that is a request per keystroke at a
/// server that also throttles at its end. The cooldown is the machine being well behaved rather
/// than the server having to be.
public actor MachineMembers {
    private let fetch: @Sendable () async throws -> [WorkspaceMember]
    private let now: @Sendable () -> Date
    /// The shortest gap between two asks caused by a miss. A hit never asks at all.
    static let cooldown: TimeInterval = 30
    /// How long a list is used before the next miss is allowed to refresh it. A hit inside this is
    /// answered from memory; nothing expires on a timer, because a list nobody asks about costs
    /// nothing and refreshing it would wake a machine to no purpose.
    private var members: [String: WorkspaceMember] = [:]
    private var lastFetchAt: Date?
    private var hasFetched = false

    public init(now: @escaping @Sendable () -> Date = Date.init, fetch: @escaping @Sendable () async throws -> [WorkspaceMember]) {
        self.fetch = fetch
        self.now = now
    }

    /// Whether this id may be addressed here.
    ///
    /// **Three answers, and `unknown` is not `notAMember`.** Never having been told who the team is
    /// and being told this person is not in it are different facts, and a machine that collapsed
    /// them would refuse everybody identically the first time runbloom.app was unreachable.
    public func look(up userID: String) async -> MemberLookup {
        if let found = members[userID] { return .member(found) }
        guard mayRefetch else { return hasFetched ? .notAMember : .unknown }
        await refresh()
        if let found = members[userID] { return .member(found) }
        return hasFetched ? .notAMember : .unknown
    }

    /// Everybody, for a client offering completion. Empty until the first successful fetch.
    public func all() async -> [WorkspaceMember] {
        if !hasFetched, mayRefetch { await refresh() }
        return members.values.sorted { $0.handle < $1.handle }
    }

    private var mayRefetch: Bool {
        guard let lastFetchAt else { return true }
        return now().timeIntervalSince(lastFetchAt) >= Self.cooldown
    }

    private func refresh() async {
        lastFetchAt = now()
        guard let fetched = try? await fetch() else { return }
        // Replaced rather than merged: somebody who has left the team has to stop being
        // addressable, and a merge would keep them for ever.
        members = Dictionary(fetched.map { ($0.userID, $0) }, uniquingKeysWith: { _, second in second })
        hasFetched = true
    }
}

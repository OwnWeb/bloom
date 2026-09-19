import BloomProtocol
import Foundation

/// A message from an agent in a Bloom Cloud workspace for a workspace on this Mac, which runbloom.app
/// held because this Mac had no stream open to that workspace when it was sent.
///
/// `GET /api/v1/me/mac-messages` answers with the signed-in person's own, oldest first, and
/// `DELETE /api/v1/me/mac-messages/{id}` acknowledges one. They expire after seven days, and go if
/// the person leaves the team. The same message a live stream carries as `mac_message`, so it goes
/// through the same intake: see `record(for:)`.
public struct DepositedMacMessage: Decodable, Sendable, Hashable, Identifiable {
    public struct Named: Decodable, Sendable, Hashable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Via: Decodable, Sendable, Hashable {
        public var chat: String?

        public init(chat: String?) { self.chat = chat }
    }

    public var id: String
    public var team: Named?
    public var fromWorkspace: Named
    public var via: Via?
    /// The local workspace's name, as the agent was given it.
    public var targetWorkspace: String
    public var text: String
    public var createdAt: String?
    public var expiresAt: String?

    public init(
        id: String, team: Named? = nil, fromWorkspace: Named, via: Via? = nil, targetWorkspace: String,
        text: String, createdAt: String? = nil, expiresAt: String? = nil
    ) {
        self.id = id
        self.team = team
        self.fromWorkspace = fromWorkspace
        self.via = via
        self.targetWorkspace = targetWorkspace
        self.text = text
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case id, team, via, text
        case fromWorkspace = "from_workspace"
        case targetWorkspace = "target_workspace"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    /// The live stream's record for the same message, addressed to `userID`, which is the person
    /// signed in: runbloom.app only ever answers with that person's own, so the account the intake
    /// checks against is the one that asked.
    public func record(for userID: String) -> MacMessageRecord {
        MacMessageRecord(
            id: id, userID: userID, workspace: targetWorkspace, text: text,
            via: ViaRecord(workspace: fromWorkspace.name, chat: via?.chat)
        )
    }
}

/// The page `GET /api/v1/me/mac-messages` answers with.
struct DepositedMacMessages: Decodable {
    var messages: [DepositedMacMessage]
}

/// Taking what runbloom.app holds for this Mac, one message at a time, oldest first.
///
/// **Acknowledged only once it has landed**, so a Mac that quits or crashes halfway through the
/// list loses nothing: what was not acknowledged is offered again on the next drain. What landing
/// means is the caller's, and comes back as a `Landing`.
///
/// **One drain at a time.** A drain is started from the list refresh, from signing in and from a
/// stream reconnecting, which can all happen in the same second, and two at once would land the
/// same message twice before either acknowledged it. The second is skipped, which loses nothing,
/// because the next refresh drains again.
public actor MacMessageDrain {
    public enum Landing: Sendable, Equatable {
        /// In, or known to be in already, or told to the person because it cannot go in. Either
        /// way it is done with, so it is acknowledged.
        case settled
        /// Not now: offered again next time.
        case later
    }

    private var draining = false

    public init() {}

    /// - Returns: the ids acknowledged, or nil when another drain was already running.
    @discardableResult
    public func drain(
        list: @Sendable () async throws -> [DepositedMacMessage],
        land: @Sendable (DepositedMacMessage) async -> Landing,
        acknowledge: @Sendable (String) async throws -> Void
    ) async -> [String]? {
        guard !draining else { return nil }
        draining = true
        defer { draining = false }
        // Nothing to do on a failure to list: the server may not have the route yet, or be
        // unreachable, and the next refresh asks again.
        guard let messages = try? await list() else { return [] }
        var acknowledged: [String] = []
        for message in messages where await land(message) == .settled {
            // A failed acknowledgement is offered again and dropped as a duplicate then.
            if (try? await acknowledge(message.id)) != nil { acknowledged.append(message.id) }
        }
        return acknowledged
    }
}

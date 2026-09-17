import Foundation

/// What `POST /api/v1/cloud-workspaces/{id}/session-token` answers: a five minute token for one
/// workspace's machine, where that machine is, and whether it was awake when last seen.
public struct SessionToken: Codable, Sendable, Hashable {
    public var token: String
    public var expiresAt: Date
    public var machineURL: URL
    /// The last known state, not a promise. A machine reported asleep is woken by the first
    /// request made with this token, which is why a client shows that it is waking.
    public var awake: Bool
    public var abilities: [String]

    public init(token: String, expiresAt: Date, machineURL: URL, awake: Bool, abilities: [String]) {
        self.token = token
        self.expiresAt = expiresAt
        self.machineURL = machineURL
        self.awake = awake
        self.abilities = abilities
    }

    enum CodingKeys: String, CodingKey {
        case token, awake, abilities
        case expiresAt = "expires_at"
        case machineURL = "machine_url"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        expiresAt = try c.decode(RunbloomDate.self, forKey: .expiresAt).date
        machineURL = try c.decode(URL.self, forKey: .machineURL)
        awake = try c.decodeIfPresent(Bool.self, forKey: .awake) ?? false
        abilities = try c.decodeIfPresent([String].self, forKey: .abilities) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(RunbloomDate(expiresAt), forKey: .expiresAt)
        try c.encode(machineURL, forKey: .machineURL)
        try c.encode(awake, forKey: .awake)
        try c.encode(abilities, forKey: .abilities)
    }

    public func allows(_ ability: String) -> Bool { abilities.contains(ability) }

    /// Whether this token should be replaced before it is used again: within a minute of its
    /// expiry, which is the margin the protocol asks a stream's token to be refreshed by.
    public func needsRefresh(at now: Date, margin: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= margin
    }
}

/// What `POST /api/v1/cloud-workspaces/{id}/preview-token` answers: a sixty second single use
/// token, and the address that spends it, which is opened top level in a browser.
public struct PreviewToken: Codable, Sendable, Hashable {
    public var token: String
    public var expiresAt: Date
    public var enterURL: URL

    public init(token: String, expiresAt: Date, enterURL: URL) {
        self.token = token
        self.expiresAt = expiresAt
        self.enterURL = enterURL
    }

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case enterURL = "enter_url"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        expiresAt = try c.decode(RunbloomDate.self, forKey: .expiresAt).date
        enterURL = try c.decode(URL.self, forKey: .enterURL)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(RunbloomDate(expiresAt), forKey: .expiresAt)
        try c.encode(enterURL, forKey: .enterURL)
    }
}

/// Who a Cloud workspace is shared with: `GET`, `POST /api/v1/cloud-workspaces/{id}/members`.
public struct CloudWorkspaceMembers: Codable, Sendable, Hashable {
    public var sharedWithTeam: Bool
    public var members: [Member]

    public init(sharedWithTeam: Bool, members: [Member]) {
        self.sharedWithTeam = sharedWithTeam
        self.members = members
    }

    public struct Member: Codable, Sendable, Hashable, Identifiable {
        public var user: RunbloomPerson
        /// `owner` or `collaborator`.
        public var role: String

        public var id: String { user.id }

        public init(user: RunbloomPerson, role: String) {
            self.user = user
            self.role = role
        }
    }

    enum CodingKeys: String, CodingKey {
        case members
        case sharedWithTeam = "shared_with_team"
    }

    /// Whether anybody but the owner can open it, which is what switches every turn to the team key.
    public var isShared: Bool { sharedWithTeam || members.contains { $0.role != "owner" } }
}

/// A public preview link: `https://runbloom.app/share/<id>`, revocable, lasting a week unless
/// asked otherwise.
public struct PreviewShare: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var url: URL
    public var createdAt: Date?
    public var expiresAt: Date?
    public var createdBy: RunbloomPerson?

    public init(id: String, url: URL, createdAt: Date? = nil, expiresAt: Date? = nil, createdBy: RunbloomPerson? = nil) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.createdBy = createdBy
    }

    enum CodingKeys: String, CodingKey {
        case id, url
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case createdBy = "created_by"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        createdAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .createdAt)?.date
        expiresAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .expiresAt)?.date
        createdBy = try c.decodeIfPresent(RunbloomPerson.self, forKey: .createdBy)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(createdAt.map(RunbloomDate.init), forKey: .createdAt)
        try c.encodeIfPresent(expiresAt.map(RunbloomDate.init), forKey: .expiresAt)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
    }
}

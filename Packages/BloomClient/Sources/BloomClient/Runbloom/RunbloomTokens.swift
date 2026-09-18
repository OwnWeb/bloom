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
    /// Who this token was minted for, which is the same id the machine records in
    /// `author.user_id` and the same one the member list uses.
    ///
    /// **It is here so a client can tell its own messages from everybody else's before it has an
    /// account object**, which is the window the Mac used to draw the reader's own words in the
    /// colour reserved for a teammate. It is the token's own `sub`, and runbloom.app has a test
    /// pinning the two together, **so read this field and never decode the token**: parsing it
    /// would give this client an opinion about the token's shape that everybody afterwards would
    /// have to keep, for a value that is handed over anyway.
    ///
    /// Optional because it is additive: an older control server sends none, and every recorded
    /// fixture predates it. See `MessageAuthorship.isFromSomebodyElse`.
    public var userID: String?

    public init(
        token: String, expiresAt: Date, machineURL: URL, awake: Bool, abilities: [String],
        userID: String? = nil
    ) {
        self.token = token
        self.expiresAt = expiresAt
        self.machineURL = machineURL
        self.awake = awake
        self.abilities = abilities
        self.userID = userID
    }

    enum CodingKeys: String, CodingKey {
        case token, awake, abilities
        case expiresAt = "expires_at"
        case machineURL = "machine_url"
        case userID = "user_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        expiresAt = try c.decode(RunbloomDate.self, forKey: .expiresAt).date
        machineURL = try c.decode(URL.self, forKey: .machineURL)
        awake = try c.decodeIfPresent(Bool.self, forKey: .awake) ?? false
        abilities = try c.decodeIfPresent([String].self, forKey: .abilities) ?? []
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(RunbloomDate(expiresAt), forKey: .expiresAt)
        try c.encode(machineURL, forKey: .machineURL)
        try c.encode(awake, forKey: .awake)
        try c.encode(abilities, forKey: .abilities)
        try c.encodeIfPresent(userID, forKey: .userID)
    }

    public func allows(_ ability: String) -> Bool { abilities.contains(ability) }

    /// Whether the machine's address is one a bearer token may be sent to: HTTPS, with no user or
    /// password in it, or plain HTTP only to this Mac for a development machine. A token sent over
    /// plain HTTP to anywhere else would be readable on the way.
    public var hasSafeMachineURL: Bool { Self.isSafe(machineURL) }

    static func isSafe(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host(), !host.isEmpty else { return false }
        if url.scheme == "https" { return true }
        return url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    static let unsafeMachineURL = RunbloomRefusal(
        status: 200, code: "unsafe_machine_url",
        message: "runbloom.app gave an address for this Cloud workspace that is not secure, so Bloom did not connect to it."
    )

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

    /// Whether the address is safe to open: the machine's own host, over HTTPS, and never another
    /// scheme, which `NSWorkspace` would hand to whatever application claims it.
    public func isSafe(forMachine machine: URL?) -> Bool {
        guard SessionToken.isSafe(enterURL), enterURL.path() == "/_bloom/preview/enter" else { return false }
        guard let machine else { return true }
        return machine.host()?.lowercased() == enterURL.host()?.lowercased() && machine.port == enterURL.port
    }

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

        /// False when this person cannot push to the repository or has not connected GitHub, which in
        /// a shared workspace means they cannot prompt (runbloom.app refuses with `no_push_access`).
        /// Nil when runbloom.app never checked or could not reach GitHub, which says nothing either way.
        public var hasPushAccess: Bool?

        public var id: String { user.id }

        public init(user: RunbloomPerson, role: String, hasPushAccess: Bool? = nil) {
            self.user = user
            self.role = role
            self.hasPushAccess = hasPushAccess
        }

        enum CodingKeys: String, CodingKey {
            case user, role
            case hasPushAccess = "push_access"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            user = try c.decode(RunbloomPerson.self, forKey: .user)
            role = try c.decodeIfPresent(String.self, forKey: .role) ?? "collaborator"
            hasPushAccess = try? c.decodeIfPresent(Bool.self, forKey: .hasPushAccess)
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

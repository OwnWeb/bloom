import Foundation

/// The signed in person as `GET /api/v1/me` answers: who they are, the teams they are in, and
/// what they have connected.
///
/// Every field a later runbloom.app might leave out decodes to its empty value rather than failing,
/// because the account is what the Settings pane and the signed out state are drawn from, and a
/// field added or dropped on the server must not look like being signed out.
public struct RunbloomAccount: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var email: String
    public var avatarURL: URL?
    public var currentTeamID: String?
    public var githubConnected: Bool
    public var agentKeys: [AgentKeyStatus]
    public var teams: [RunbloomTeam]

    public init(
        id: String, name: String, email: String, avatarURL: URL? = nil, currentTeamID: String? = nil,
        githubConnected: Bool = false, agentKeys: [AgentKeyStatus] = [], teams: [RunbloomTeam] = []
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
        self.currentTeamID = currentTeamID
        self.githubConnected = githubConnected
        self.agentKeys = agentKeys
        self.teams = teams
    }

    enum CodingKeys: String, CodingKey {
        case id, name, email, teams
        case avatarURL = "avatar_url"
        case currentTeamID = "current_team_id"
        case githubConnected = "github_connected"
        case agentKeys = "agent_keys"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        avatarURL = try? c.decodeIfPresent(URL.self, forKey: .avatarURL)
        currentTeamID = try c.decodeIfPresent(String.self, forKey: .currentTeamID)
        githubConnected = try c.decodeIfPresent(Bool.self, forKey: .githubConnected) ?? false
        agentKeys = try c.decodeIfPresent([AgentKeyStatus].self, forKey: .agentKeys) ?? []
        teams = try c.decodeIfPresent([RunbloomTeam].self, forKey: .teams) ?? []
    }

    /// The teams that can hold Cloud workspaces, in the order runbloom.app listed them.
    public var cloudTeams: [RunbloomTeam] { teams.filter(\.cloudWorkspacesEnabled) }

    /// Whether a prompt with this agent in this team would find a key: a team key, or a personal
    /// one. A personal key only counts in a workspace that is not shared, which runbloom.app decides
    /// when the turn starts; this is for saying what is missing before anyone tries.
    public func hasAgentKey(team: String, agent: String) -> Bool {
        agentKeys.contains { $0.teamID == team && $0.agent == agent && ($0.teamKey || $0.personalKey) }
    }
}

/// One team and the signed in person's role in it.
public struct RunbloomTeam: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var slug: String
    public var role: String
    public var cloudWorkspacesEnabled: Bool

    public init(id: String, name: String, slug: String = "", role: String = "member", cloudWorkspacesEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.slug = slug
        self.role = role
        self.cloudWorkspacesEnabled = cloudWorkspacesEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, role
        case cloudWorkspacesEnabled = "cloud_workspaces_enabled"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "member"
        cloudWorkspacesEnabled = try c.decodeIfPresent(Bool.self, forKey: .cloudWorkspacesEnabled) ?? false
    }
}

/// Whether a team key and a personal key are set for one agent in one team. Booleans only: a key
/// never leaves runbloom.app.
public struct AgentKeyStatus: Codable, Sendable, Hashable {
    public var teamID: String
    public var agent: String
    public var teamKey: Bool
    public var personalKey: Bool

    public init(teamID: String, agent: String, teamKey: Bool, personalKey: Bool) {
        self.teamID = teamID
        self.agent = agent
        self.teamKey = teamKey
        self.personalKey = personalKey
    }

    enum CodingKeys: String, CodingKey {
        case agent
        case teamID = "team_id"
        case teamKey = "team_key"
        case personalKey = "personal_key"
    }
}

/// A repository a team can create Cloud workspaces for, from `GET /api/v1/teams/{team}/projects`.
public struct RunbloomProject: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `owner/name`, as GitHub spells it.
    public var repository: String
    public var defaultBranch: String
    public var machineSize: String?

    public init(id: String, repository: String, defaultBranch: String = "main", machineSize: String? = nil) {
        self.id = id
        self.repository = repository
        self.defaultBranch = defaultBranch
        self.machineSize = machineSize
    }

    enum CodingKeys: String, CodingKey {
        case id, repository
        case defaultBranch = "default_branch"
        case machineSize = "machine_size"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repository = try c.decode(String.self, forKey: .repository)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch) ?? "main"
        machineSize = try c.decodeIfPresent(String.self, forKey: .machineSize)
    }
}

/// Somebody in a team, for choosing collaborators.
public struct RunbloomPerson: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var email: String?
    public var avatarURL: URL?

    public init(id: String, name: String, email: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
    }

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case avatarURL = "avatar_url"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email)
        avatarURL = try? c.decodeIfPresent(URL.self, forKey: .avatarURL)
    }
}

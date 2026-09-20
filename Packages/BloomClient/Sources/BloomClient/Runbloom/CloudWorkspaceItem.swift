import Foundation

/// One Cloud workspace as runbloom.app lists it, which is what the sidebar draws before anything
/// is opened: `GET /api/v1/teams/{team}/cloud-workspaces` and `GET /api/v1/cloud-workspaces/{id}`.
///
/// **Reading this never wakes a machine.** runbloom.app answers from its own database, from the
/// last summary the machine posted, so a list of sleeping workspaces costs nothing to poll.
public struct CloudWorkspaceItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var teamID: String
    public var name: String
    public var project: ProjectReference?
    public var branch: String
    public var baseBranch: String
    /// runbloom.app's lifecycle state: the summary's `state` (`setting_up`, `setup_failed`,
    /// `idle`, `running`, `waiting_for_input`, `blocked`, `stopping`, `error`), plus `archiving`
    /// and `archived`, which only runbloom.app knows.
    public var state: String
    public var sharedWithTeam: Bool
    public var owner: RunbloomPerson?
    /// `owner`, `collaborator`, or nil for a team owner or admin who can see a private workspace
    /// exists and archive it, but not open it.
    public var role: String?
    public var canOpen: Bool
    public var canArchive: Bool
    /// This person's private mark for the workspace, from the shared Mac palette.
    public var colour: String?
    /// Whether runbloom.app will let this person change that mark.
    public var canColour: Bool
    /// The mutation endpoint runbloom.app supplied for that mark.
    public var colourURL: String?
    public var unread: Bool
    public var summary: CloudWorkspaceSummary?
    public var createdAt: Date?
    public var archivedAt: Date?
    /// What runbloom.app currently needs to say about this workspace, when that is worth saying.
    /// Nil almost always. See `CloudWorkspaceNotice`.
    public var workspaceNotice: CloudWorkspaceNotice?
    /// The web address a person opens to be in this workspace, when runbloom.app said. It is
    /// runbloom.app's route to state, never built here from a team slug and an id. Nil from a
    /// server older than the field. `cloud_workspace_start` hands it to the agent that asked.
    public var url: String?

    public init(
        id: String, teamID: String, name: String, project: ProjectReference? = nil, branch: String, baseBranch: String = "main",
        state: String, sharedWithTeam: Bool = false, owner: RunbloomPerson? = nil, role: String? = "owner", canOpen: Bool = true,
        canArchive: Bool = true, colour: String? = nil, canColour: Bool = false, colourURL: String? = nil,
        unread: Bool = false, summary: CloudWorkspaceSummary? = nil, createdAt: Date? = nil, archivedAt: Date? = nil
    ) {
        self.id = id
        self.teamID = teamID
        self.name = name
        self.project = project
        self.branch = branch
        self.baseBranch = baseBranch
        self.state = state
        self.sharedWithTeam = sharedWithTeam
        self.owner = owner
        self.role = role
        self.canOpen = canOpen
        self.canArchive = canArchive
        self.colour = colour
        self.canColour = canColour
        self.colourURL = colourURL
        self.unread = unread
        self.summary = summary
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    public struct ProjectReference: Codable, Sendable, Hashable {
        public var id: String
        public var repository: String
        /// The authorised project settings endpoint runbloom.app supplied.
        public var settingsURL: String?
        /// The authorised browser page runbloom.app supplied. Kept apart from the API endpoint so
        /// a client can never put bearer credentials on a browser navigation by confusing them.
        public var browserSettingsURL: String?

        public init(
            id: String, repository: String, settingsURL: String? = nil, browserSettingsURL: String? = nil
        ) {
            self.id = id
            self.repository = repository
            self.settingsURL = settingsURL
            self.browserSettingsURL = browserSettingsURL
        }

        enum CodingKeys: String, CodingKey {
            case id, repository
            case settingsURL = "settings_url"
            case browserSettingsURL = "browser_settings_url"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            repository = try c.decode(String.self, forKey: .repository)
            settingsURL = try c.decodeIfPresent(String.self, forKey: .settingsURL)
            // A bad optional browser link hides one menu action rather than losing the workspace.
            browserSettingsURL = try? c.decodeIfPresent(String.self, forKey: .browserSettingsURL)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(repository, forKey: .repository)
            try c.encodeIfPresent(settingsURL, forKey: .settingsURL)
            try c.encodeIfPresent(browserSettingsURL, forKey: .browserSettingsURL)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, project, branch, state, owner, role, colour, unread, summary
        case teamID = "team_id"
        case baseBranch = "base_branch"
        case sharedWithTeam = "shared_with_team"
        case canOpen = "can_open"
        case canArchive = "can_archive"
        case canColour = "can_colour"
        case colourURL = "colour_url"
        case createdAt = "created_at"
        case archivedAt = "archived_at"
        case workspaceNotice = "workspace_notice"
        case legacyRunnerNotice = "runner_notice"
        case url
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        project = try c.decodeIfPresent(ProjectReference.self, forKey: .project)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "setting_up"
        sharedWithTeam = try c.decodeIfPresent(Bool.self, forKey: .sharedWithTeam) ?? false
        owner = try c.decodeIfPresent(RunbloomPerson.self, forKey: .owner)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        canOpen = try c.decodeIfPresent(Bool.self, forKey: .canOpen) ?? (role != nil)
        canArchive = try c.decodeIfPresent(Bool.self, forKey: .canArchive) ?? (role == "owner")
        colour = try? c.decodeIfPresent(String.self, forKey: .colour)
        canColour = try c.decodeIfPresent(Bool.self, forKey: .canColour) ?? false
        colourURL = try? c.decodeIfPresent(String.self, forKey: .colourURL)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        // A summary this client cannot read is shown as no summary, never as a list that failed:
        // the machine and runbloom.app release separately, and the list is the whole sidebar.
        summary = try? c.decodeIfPresent(CloudWorkspaceSummary.self, forKey: .summary)
        createdAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .createdAt)?.date
        archivedAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .archivedAt)?.date
        // Read tolerantly, for the reason the summary is: a notice this version cannot read must
        // not cost the whole list.
        workspaceNotice = (try? c.decodeIfPresent(CloudWorkspaceNotice.self, forKey: .workspaceNotice))
            ?? (try? c.decodeIfPresent(CloudWorkspaceNotice.self, forKey: .legacyRunnerNotice))
        url = try? c.decodeIfPresent(String.self, forKey: .url)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(teamID, forKey: .teamID)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(branch, forKey: .branch)
        try c.encode(baseBranch, forKey: .baseBranch)
        try c.encode(state, forKey: .state)
        try c.encode(sharedWithTeam, forKey: .sharedWithTeam)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encode(canOpen, forKey: .canOpen)
        try c.encode(canArchive, forKey: .canArchive)
        try c.encodeIfPresent(colour, forKey: .colour)
        try c.encode(canColour, forKey: .canColour)
        try c.encodeIfPresent(colourURL, forKey: .colourURL)
        try c.encode(unread, forKey: .unread)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(createdAt.map(RunbloomDate.init), forKey: .createdAt)
        try c.encodeIfPresent(archivedAt.map(RunbloomDate.init), forKey: .archivedAt)
        try c.encodeIfPresent(workspaceNotice, forKey: .workspaceNotice)
        try c.encodeIfPresent(url, forKey: .url)
    }

    /// The name to draw: the summary's title once the machine has named the workspace, which is
    /// where a rename lands, and the name it was created with until then.
    public var displayName: String {
        if let title = summary?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return name
    }

    /// The branch to draw, from the summary when the machine has renamed it.
    public var displayBranch: String {
        if let branch = summary?.branch, !branch.isEmpty { return branch }
        return branch
    }

    /// Whether this person can prompt in it at all: an owner or a collaborator. A team admin who
    /// only sees that a private workspace exists has no role.
    public var isMember: Bool { role != nil }

    /// Whether the machine was awake when it last reported. A sleeping workspace is still ready.
    public var isAwake: Bool { summary?.awake ?? false }

    /// Whether an agent on this Mac may reach it through the bridge: list it, read it, message it.
    ///
    /// **Only what the signed-in person could open themselves**, and not archived or on its way
    /// there. A team owner or admin is sent a teammate's private workspace so they can see it
    /// exists and archive it, with `canOpen` false, and an agent working for them must not be
    /// handed what they cannot open. `workspace_list` lists these and nothing else, and every
    /// other bridge call on a Bloom Cloud workspace is refused for anything not among them.
    public var isReachableFromBridge: Bool {
        canOpen && archivedAt == nil && state != "archiving" && state != "archived"
    }
}

/// The summary a machine last posted, as runbloom.app stored it. Only what a client draws is
/// decoded; see "Summaries" in docs/REMOTE-WORKSPACES.md for the whole of it.
public struct CloudWorkspaceSummary: Codable, Sendable, Hashable {
    public var revision: Int?
    public var observedAt: Date?
    public var title: String?
    public var branch: String?
    public var state: String?
    public var awake: Bool?
    public var setup: Setup?
    public var lastMessage: LastMessage?
    public var waiting: Waiting?
    public var runningSince: Date?
    public var diff: Diff?
    public var pullRequest: PullRequest?
    public var presentUserIDs: [String]

    public init(
        revision: Int? = nil, observedAt: Date? = nil, title: String? = nil, branch: String? = nil, state: String? = nil, awake: Bool? = nil,
        setup: Setup? = nil, lastMessage: LastMessage? = nil, waiting: Waiting? = nil, runningSince: Date? = nil, diff: Diff? = nil,
        pullRequest: PullRequest? = nil, presentUserIDs: [String] = []
    ) {
        self.revision = revision
        self.observedAt = observedAt
        self.title = title
        self.branch = branch
        self.state = state
        self.awake = awake
        self.setup = setup
        self.lastMessage = lastMessage
        self.waiting = waiting
        self.runningSince = runningSince
        self.diff = diff
        self.pullRequest = pullRequest
        self.presentUserIDs = presentUserIDs
    }

    public struct Setup: Codable, Sendable, Hashable {
        public var state: String
        public var step: String?

        public init(state: String, step: String? = nil) {
            self.state = state
            self.step = step
        }
    }

    public struct LastMessage: Codable, Sendable, Hashable {
        public var chatID: String?
        public var authorKind: String?
        public var authorUserID: String?
        public var excerpt: String?
        public var at: Date?

        public init(chatID: String? = nil, authorKind: String? = nil, authorUserID: String? = nil, excerpt: String? = nil, at: Date? = nil) {
            self.chatID = chatID
            self.authorKind = authorKind
            self.authorUserID = authorUserID
            self.excerpt = excerpt
            self.at = at
        }

        enum CodingKeys: String, CodingKey {
            case excerpt, at
            case chatID = "chat_id"
            case authorKind = "author_kind"
            case authorUserID = "author_user_id"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chatID = try c.decodeIfPresent(String.self, forKey: .chatID)
            authorKind = try c.decodeIfPresent(String.self, forKey: .authorKind)
            authorUserID = try c.decodeIfPresent(String.self, forKey: .authorUserID)
            excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt)
            at = try c.decodeIfPresent(RunbloomDate.self, forKey: .at)?.date
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(chatID, forKey: .chatID)
            try c.encodeIfPresent(authorKind, forKey: .authorKind)
            try c.encodeIfPresent(authorUserID, forKey: .authorUserID)
            try c.encodeIfPresent(excerpt, forKey: .excerpt)
            try c.encodeIfPresent(at.map(RunbloomDate.init), forKey: .at)
        }
    }

    public struct Waiting: Codable, Sendable, Hashable {
        /// `permission`, `question` or `plan`.
        public var kind: String
        public var chatID: String?

        public init(kind: String, chatID: String? = nil) {
            self.kind = kind
            self.chatID = chatID
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case chatID = "chat_id"
        }
    }

    public struct Diff: Codable, Sendable, Hashable {
        public var files: Int
        public var additions: Int
        public var deletions: Int

        public init(files: Int, additions: Int, deletions: Int) {
            self.files = files
            self.additions = additions
            self.deletions = deletions
        }
    }

    public struct PullRequest: Codable, Sendable, Hashable {
        public var number: Int?
        public var url: String?
        public var state: String?

        public init(number: Int? = nil, url: String? = nil, state: String? = nil) {
            self.number = number
            self.url = url
            self.state = state
        }
    }

    enum CodingKeys: String, CodingKey {
        case revision, title, branch, state, awake, setup, waiting, diff
        case observedAt = "observed_at"
        case lastMessage = "last_message"
        case runningSince = "running_since"
        case pullRequest = "pull_request"
        case presentUserIDs = "present_user_ids"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try? c.decodeIfPresent(Int.self, forKey: .revision)
        observedAt = try? c.decodeIfPresent(RunbloomDate.self, forKey: .observedAt)?.date
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        branch = try? c.decodeIfPresent(String.self, forKey: .branch)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        awake = try? c.decodeIfPresent(Bool.self, forKey: .awake)
        setup = try? c.decodeIfPresent(Setup.self, forKey: .setup)
        lastMessage = try? c.decodeIfPresent(LastMessage.self, forKey: .lastMessage)
        waiting = try? c.decodeIfPresent(Waiting.self, forKey: .waiting)
        runningSince = try? c.decodeIfPresent(RunbloomDate.self, forKey: .runningSince)?.date
        diff = try? c.decodeIfPresent(Diff.self, forKey: .diff)
        pullRequest = try? c.decodeIfPresent(PullRequest.self, forKey: .pullRequest)
        presentUserIDs = (try? c.decodeIfPresent([String].self, forKey: .presentUserIDs)) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encodeIfPresent(observedAt.map(RunbloomDate.init), forKey: .observedAt)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(awake, forKey: .awake)
        try c.encodeIfPresent(setup, forKey: .setup)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try c.encodeIfPresent(waiting, forKey: .waiting)
        try c.encodeIfPresent(runningSince.map(RunbloomDate.init), forKey: .runningSince)
        try c.encodeIfPresent(diff, forKey: .diff)
        try c.encodeIfPresent(pullRequest, forKey: .pullRequest)
        try c.encode(presentUserIDs, forKey: .presentUserIDs)
    }
}

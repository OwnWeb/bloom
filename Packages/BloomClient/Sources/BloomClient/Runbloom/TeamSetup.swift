import Foundation

/// What a team still needs before Cloud workspaces work in it, as runbloom.app reports it per team:
/// whether the team is in early access at all, and the checklist on its Dashboard.
///
/// Every field is optional, because a runbloom.app older than this checklist says none of it, and
/// "not said" must read as "nothing known" rather than as "missing". Only a field that says false is
/// a step still to take.
public struct TeamSetup: Codable, Sendable, Hashable {
    public var enabled: Bool?
    /// runbloom.app's own verdict on the four steps below, which is what the app trusts when it is
    /// there: a step this version does not know about is still counted there and not here.
    public var setupComplete: Bool?
    public var githubConnected: Bool?
    public var githubAppInstalled: Bool?
    public var hasProject: Bool?
    public var hasAgentKey: Bool?
    /// The team's Dashboard checklist on runbloom.app, where every step is taken.
    public var setupURL: URL?

    public init(
        enabled: Bool? = nil, setupComplete: Bool? = nil, githubConnected: Bool? = nil, githubAppInstalled: Bool? = nil,
        hasProject: Bool? = nil, hasAgentKey: Bool? = nil, setupURL: URL? = nil
    ) {
        self.enabled = enabled
        self.setupComplete = setupComplete
        self.githubConnected = githubConnected
        self.githubAppInstalled = githubAppInstalled
        self.hasProject = hasProject
        self.hasAgentKey = hasAgentKey
        self.setupURL = setupURL
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case setupComplete = "setup_complete"
        case githubConnected = "github_connected"
        case githubAppInstalled = "github_app_installed"
        case hasProject = "has_project"
        case hasAgentKey = "has_agent_key"
        case setupURL = "setup_url"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        setupComplete = try? c.decodeIfPresent(Bool.self, forKey: .setupComplete)
        githubConnected = try? c.decodeIfPresent(Bool.self, forKey: .githubConnected)
        githubAppInstalled = try? c.decodeIfPresent(Bool.self, forKey: .githubAppInstalled)
        hasProject = try? c.decodeIfPresent(Bool.self, forKey: .hasProject)
        hasAgentKey = try? c.decodeIfPresent(Bool.self, forKey: .hasAgentKey)
        setupURL = try? c.decodeIfPresent(URL.self, forKey: .setupURL)
    }

    var saysAnything: Bool {
        [enabled, setupComplete, githubConnected, githubAppInstalled, hasProject, hasAgentKey].contains { $0 != nil } || setupURL != nil
    }

    /// Whether every step is done. runbloom.app's own answer when it gave one, because it counts
    /// steps this version may not have heard of; otherwise the four this version knows.
    public var isComplete: Bool { setupComplete ?? missing.isEmpty }

    /// The steps still to take, in the order the account page lists them, as sentences.
    ///
    /// `github_connected` is about the signed in person; the other three are the team's. Only a
    /// step runbloom.app said false is listed: not said is not the same as not done.
    public var missing: [String] {
        var steps: [String] = []
        if githubConnected == false { steps.append("Connect your GitHub account.") }
        if githubAppInstalled == false { steps.append("Install the Bloom GitHub App for the team.") }
        if hasProject == false { steps.append("Add a repository as a project.") }
        if hasAgentKey == false { steps.append("Add a Claude Code or Codex API key.") }
        return steps
    }

    /// The page to send somebody to (`https://runbloom.app/account/<team>`), and only when it is
    /// runbloom.app's own: the address came from an answer, and a button that opens it should not
    /// open anywhere else.
    public func setupPage(on environment: RunbloomEnvironment) -> URL? {
        guard let setupURL, BloomAuthDocument.sameOrigin(setupURL, environment.origin) else { return nil }
        return setupURL
    }
}

/// What the app says about a team that cannot hold Cloud workspaces yet, for the create sheet and
/// the Settings pane, so the two say the same thing.
public struct TeamSetupNotice: Sendable, Hashable {
    public var sentence: String
    public var steps: [String]
    /// The Dashboard checklist, when there is somewhere to finish.
    public var setupPage: URL?

    public static let buttonTitle = "Finish setting up on runbloom.app"

    /// Nil for a team that is ready, as far as runbloom.app said.
    public init?(team: RunbloomTeam, environment: RunbloomEnvironment) {
        let page = team.setup?.setupPage(on: environment)
        guard team.cloudWorkspacesEnabled else {
            sentence = "Cloud workspaces are in early access, and \(team.name.isEmpty ? "this team" : team.name) is not in it yet."
            // The steps are still listed: runbloom.app reports them whether or not the team is in
            // early access yet, and they are worth doing before it is.
            steps = team.setup?.missing ?? []
            setupPage = page
            return
        }
        let missing = team.setup?.missing ?? []
        guard !missing.isEmpty || team.setup?.isComplete == false else { return nil }
        sentence = "\(team.name.isEmpty ? "This team" : team.name) needs a few things before it can create Cloud workspaces."
        steps = missing
        setupPage = page
    }
}

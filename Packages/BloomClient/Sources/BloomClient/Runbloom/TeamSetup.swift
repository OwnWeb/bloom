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

    /// The steps still to take, in the order runbloom.app's setup checklist lists them.
    ///
    /// `github_connected` is about the signed in person; the other three are the team's. Only a
    /// step runbloom.app said false is listed: not said is not the same as not done.
    public var missingSteps: [TeamSetupStep] {
        var steps: [TeamSetupStep] = []
        if githubConnected == false { steps.append(.connectGitHub) }
        if githubAppInstalled == false { steps.append(.installGitHubApp) }
        if hasProject == false { steps.append(.addProject) }
        if hasAgentKey == false { steps.append(.addAgentKey) }
        return steps
    }

    /// The same steps as sentences.
    public var missing: [String] { missingSteps.map(\.sentence) }

    /// The page to send somebody to, as runbloom.app gave it, and only when it is runbloom.app's
    /// own: the address came from an answer, and a button that opens it should not open anywhere
    /// else.
    ///
    /// **The same page for every step, opened as given.** It used to have `projects` or
    /// `agent-keys` put on the end of it for those two steps, which was this Mac building
    /// runbloom.app's addresses: the page moved from `/account/<team>` to `/app/<team>`, the
    /// workspaces page with the whole setup checklist on it, and the two pages under it were never
    /// carried across. The step still names the button; the page is runbloom.app's to say.
    public func setupPage(on environment: RunbloomEnvironment, for step: TeamSetupStep? = nil) -> URL? {
        guard let setupURL, BloomAuthDocument.sameOrigin(setupURL, environment.origin) else { return nil }
        return setupURL
    }
}

/// One thing a team needs before Cloud workspaces work in it, and the button that goes to it.
public enum TeamSetupStep: String, Sendable, Hashable, CaseIterable {
    case connectGitHub
    case installGitHubApp
    case addProject
    case addAgentKey

    public var sentence: String {
        switch self {
        case .connectGitHub: "Connect your GitHub account."
        case .installGitHubApp: "Install the Bloom GitHub App for the team."
        case .addProject: "Add a repository as a project."
        case .addAgentKey: "Add a Claude Code or Codex API key."
        }
    }

    /// What the button says. Each names the step rather than the page, because "Finish setting up"
    /// over four different steps tells a reader nothing about which of them they are about to do.
    public var buttonTitle: String {
        switch self {
        case .connectGitHub: "Connect GitHub on runbloom.app"
        case .installGitHubApp: "Install the GitHub App on runbloom.app"
        case .addProject: "Add a project on runbloom.app"
        case .addAgentKey: "Add an API key on runbloom.app"
        }
    }

}

/// What the app says about a team that cannot hold Cloud workspaces yet, for the create sheet and
/// the Settings pane, so the two say the same thing.
public struct TeamSetupNotice: Sendable, Hashable {
    public var sentence: String
    public var steps: [String]
    /// What the one button says and where it goes: the first step still to take, because a reader
    /// with four things to do starts with the first. Nil when runbloom.app named no page.
    public var buttonTitle: String
    public var page: URL?

    public static let genericButtonTitle = "Finish setting up on runbloom.app"

    /// Nil for a team that is ready, as far as runbloom.app said.
    public init?(team: RunbloomTeam, environment: RunbloomEnvironment) {
        let steps = team.setup?.missingSteps ?? []
        let first = steps.first
        buttonTitle = first?.buttonTitle ?? Self.genericButtonTitle
        page = team.setup?.setupPage(on: environment, for: first)
        self.steps = steps.map(\.sentence)
        guard team.cloudWorkspacesEnabled else {
            sentence = "Bloom Cloud workspaces are in early access, and \(team.name.isEmpty ? "this team" : team.name) is not in it yet."
            return
        }
        guard !steps.isEmpty || team.setup?.isComplete == false else { return nil }
        sentence = "\(team.name.isEmpty ? "This team" : team.name) needs a few things before it can create Bloom Cloud workspaces."
    }
}

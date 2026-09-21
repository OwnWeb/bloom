import BloomCore
import Foundation

/// What runbloom.app wrote into the machine at bootstrap: which workspace this is, whom to trust,
/// and where to report.
///
/// **Read from disk, never from a request.** The issuer and the key set a token is checked
/// against come from here, so a token cannot name its own issuer, and a request cannot point the
/// server at another runbloom.app. The file is `/etc/bloom/workspace.json`, mode 600, because it
/// holds the workspace secret; `BLOOM_WORKSPACE_CONFIG` names another for development and tests.
public struct MachineConfiguration: Codable, Sendable, Hashable {
    public struct ProjectIcon: Codable, Sendable, Hashable {
        public var requestedRevision: Int?
        public var detectorVersion: Int?
        public var repositoryDefaultBranch: String?
        public var shouldDiscover: Bool?

        enum CodingKeys: String, CodingKey {
            case requestedRevision = "requested_revision"
            case detectorVersion = "detector_version"
            case repositoryDefaultBranch = "repository_default_branch"
            case shouldDiscover = "should_discover"
        }

        public init(requestedRevision: Int?, detectorVersion: Int?, repositoryDefaultBranch: String?, shouldDiscover: Bool?) {
            self.requestedRevision = requestedRevision
            self.detectorVersion = detectorVersion
            self.repositoryDefaultBranch = repositoryDefaultBranch
            self.shouldDiscover = shouldDiscover
        }

        var identityRequest: ProjectIconDiscoveryRequest? {
            guard let requestedRevision, (1...Int(UInt32.max)).contains(requestedRevision),
                  let detectorVersion, (1...Int(UInt16.max)).contains(detectorVersion),
                  let repositoryDefaultBranch,
                  Git.isValidBranchName(repositoryDefaultBranch)
            else { return nil }
            return ProjectIconDiscoveryRequest(
                requestedRevision: requestedRevision,
                detectorVersion: detectorVersion,
                repositoryDefaultBranch: repositoryDefaultBranch
            )
        }

        var discoveryRequest: ProjectIconDiscoveryRequest? {
            shouldDiscover == true ? identityRequest : nil
        }

        var hasValidIdentity: Bool { identityRequest != nil }
    }

    public var workspaceID: String
    public var issuer: String
    public var jwksURL: String
    public var baseURL: String
    public var workspaceSecret: String
    public var allowedOrigins: [String]
    public var publicURL: String
    /// `owner/name` on GitHub.
    public var repository: String
    public var branch: String
    public var baseBranch: String
    public var name: String
    public var teamID: String?
    /// Whether this workspace's setup scripts should run at all, which a person chose when they
    /// created it.
    ///
    /// **Optional here, and deliberately not defaulted at the property.** The two states a reader
    /// has to tell apart are `false` and *not written*, and a non-optional `Bool` with a default
    /// collapses them into one. runbloom.app writes this key on every machine it bootstraps, so in
    /// practice it is always there; a machine that meets a file without it is meeting a file
    /// written by something older, and the safe reading of that is the behaviour everything had
    /// before the key existed, which is to set up. **The writer always writes it, the reader never
    /// assumes it was written.** `runsSetup` is what the rest of the runner asks.
    ///
    /// **The same fact is `setup.enabled` on the wire, and the difference is deliberate.** This
    /// file is configuration a machine reads once and obeys, where `run_setup` is a property and
    /// reads as one. The snapshot a client gets describes what is true right now, and it sits
    /// beside a `run_setup` *method* meaning run setup again: a noun that looks like a verb, next
    /// to that verb, is the collision that has already misled a client in this codebase. Neither
    /// name is wrong at its own end, and matching them would buy consistency at the price of a
    /// worse meaning on one side. See `SetupRecord.isEnabled`, which says this from the other end
    /// so that whoever finds the inconsistency finds its reason with it.
    public var runSetup: Bool?
    /// A revisioned request from the project authority. Optional at every level so a Runner can
    /// still boot from configuration written before project icons existed.
    public var projectIcon: ProjectIcon?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case issuer
        case jwksURL = "jwks_url"
        case baseURL = "base_url"
        case workspaceSecret = "workspace_secret"
        case allowedOrigins = "allowed_origins"
        case publicURL = "public_url"
        case repository, branch, name
        case baseBranch = "base_branch"
        case teamID = "team_id"
        case runSetup = "run_setup"
        case projectIcon = "project_icon"
    }

    public static let defaultPath = "/etc/bloom/workspace.json"

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MachineConfiguration {
        let path = environment["BLOOM_WORKSPACE_CONFIG"] ?? defaultPath
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw MachineConfigurationError("Cannot read \(path): \(error.localizedDescription)")
        }
        let configuration: MachineConfiguration
        do {
            configuration = try JSONDecoder().decode(MachineConfiguration.self, from: data)
        } catch {
            throw MachineConfigurationError("\(path) is not a workspace configuration: \(error)")
        }
        try configuration.validate()
        return configuration
    }

    func validate() throws {
        for (name, value) in [("workspace_id", workspaceID), ("issuer", issuer), ("jwks_url", jwksURL), ("base_url", baseURL),
                              ("workspace_secret", workspaceSecret), ("public_url", publicURL), ("repository", repository),
                              ("branch", branch), ("base_branch", baseBranch)] where value.isEmpty {
            throw MachineConfigurationError("The workspace configuration has no \(name).")
        }
        guard repository.split(separator: "/").count == 2 else {
            throw MachineConfigurationError("The workspace configuration's repository is not owner/name.")
        }
        guard Git.isValidBranchName(branch), Git.isValidBranchName(baseBranch) else {
            throw MachineConfigurationError("The workspace configuration names a branch git would refuse.")
        }
        if projectIcon?.shouldDiscover == true, projectIconRequest == nil {
            throw MachineConfigurationError("The workspace configuration has an invalid project_icon discovery request.")
        }
    }

    /// Absent means yes. See `runSetup`.
    public var runsSetup: Bool { runSetup ?? true }

    /// Nil is an instruction to make no request, not a request to report that no icon exists.
    /// In particular, an older configuration with no `should_discover` key stays silent.
    public var projectIconRequest: ProjectIconDiscoveryRequest? {
        projectIcon?.discoveryRequest
    }

    /// The host part of the public URL, which Vite and friends want on an allow list.
    public var publicHost: String { URL(string: publicURL)?.host ?? "" }
}

public struct ProjectIconDiscoveryRequest: Codable, Sendable, Hashable {
    public var requestedRevision: Int
    public var detectorVersion: Int
    public var repositoryDefaultBranch: String

    public init(requestedRevision: Int, detectorVersion: Int, repositoryDefaultBranch: String) {
        self.requestedRevision = requestedRevision
        self.detectorVersion = detectorVersion
        self.repositoryDefaultBranch = repositoryDefaultBranch
    }
}

public struct MachineConfigurationError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Where Bloom Runner keeps what it owns on the machine, and the ports it uses.
public struct MachineLayout: Sendable, Hashable {
    /// The database and tmux socket and configuration.
    public var dataDirectory: String
    /// Where the repository is cloned.
    public var worktree: String
    /// The port Caddy listens on, which the machine's URL routes to.
    public var publicPort: Int
    /// The port Bloom Runner itself listens on, behind Caddy, on loopback only.
    public var serverPort: Int
    /// The port the project's own app is told to listen on, which the preview routes to.
    public var appPort: Int

    public init(dataDirectory: String, worktree: String, publicPort: Int = 8080, serverPort: Int = 8081, appPort: Int = 3000) {
        self.dataDirectory = dataDirectory
        self.worktree = worktree
        self.publicPort = publicPort
        self.serverPort = serverPort
        self.appPort = appPort
    }

    /// The layout on a machine, with the environment able to move any of it for development.
    public static func from(environment: [String: String] = ProcessInfo.processInfo.environment) -> MachineLayout {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return MachineLayout(
            dataDirectory: environment["BLOOM_DATA_DIR"] ?? home + "/.bloom",
            worktree: environment["BLOOM_WORKTREE"] ?? home + "/workspace",
            publicPort: environment["BLOOM_PUBLIC_PORT"].flatMap(Int.init) ?? 8080,
            serverPort: environment["BLOOM_RUNNER_PORT"].flatMap(Int.init) ?? 8081,
            appPort: environment["BLOOM_APP_PORT"].flatMap(Int.init) ?? 3000
        )
    }

    public var databasePath: String { dataDirectory + "/bloom.sqlite" }

    /// The ports a project may not have, and what has them.
    ///
    /// **A project discovers these by colliding with them.** `there-there.app` asked its `app`
    /// service for 8081, which is Bloom Runner's own port, and got `Address already in use` in a
    /// log nobody was reading, a crash loop every second, and a preview that showed a white
    /// rectangle. Nothing on the machine had ever said which numbers were taken, exactly as
    /// nothing said which port the preview reads until `BLOOM_APP_PORT` was written down. The
    /// machine knew both the whole time.
    public var reservedPorts: [(port: Int, holder: String)] {
        [(publicPort, "the preview proxy"), (serverPort, "Bloom Runner itself")]
    }
}

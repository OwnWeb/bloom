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
    }

    /// The host part of the public URL, which Vite and friends want on an allow list.
    public var publicHost: String { URL(string: publicURL)?.host ?? "" }
}

public struct MachineConfigurationError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Where bloom-server keeps what it owns on the machine, and the ports it uses.
public struct MachineLayout: Sendable, Hashable {
    /// The database, the tmux socket and configuration, the local secret.
    public var dataDirectory: String
    /// Where the repository is cloned.
    public var worktree: String
    /// The port Caddy listens on, which the machine's URL routes to.
    public var publicPort: Int
    /// The port bloom-server itself listens on, behind Caddy, on loopback only.
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
            serverPort: environment["BLOOM_SERVER_PORT"].flatMap(Int.init) ?? 8081,
            appPort: environment["BLOOM_APP_PORT"].flatMap(Int.init) ?? 3000
        )
    }

    public var databasePath: String { dataDirectory + "/bloom.sqlite" }
}

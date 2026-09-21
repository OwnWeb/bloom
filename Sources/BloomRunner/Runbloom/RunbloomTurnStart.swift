import BloomCore
import Foundation

/// What `POST .../turns/{turn}/start` hands back: a key per agent the prompter may use, and their
/// personal environment.
///
/// The description names the agents and the variables, never a value, because this is the one
/// value in the server that holds a live agent key, and a `print` or a log interpolation of the
/// synthesised description would write it out.
public struct RunbloomTurnStart: Sendable, Hashable, CustomStringConvertible {
    public var agentKeys: [AgentKind: RemoteAgentKey]
    public var environment: [String: String]

    public init(agentKeys: [AgentKind: RemoteAgentKey], environment: [String: String],
                githubCredentialGrant: RemoteGithubCredentialGrant? = nil) {
        self.agentKeys = agentKeys
        self.environment = environment
        self.githubCredentialGrant = githubCredentialGrant
    }

    public var githubCredentialGrant: RemoteGithubCredentialGrant?

    public var grant: RemoteTurnGrant {
        RemoteTurnGrant(
            agentKeys: agentKeys, environment: environment,
            githubCredentialGrant: githubCredentialGrant
        )
    }

    public var description: String {
        let agents = agentKeys.keys.map(\.wireName).sorted().joined(separator: ", ")
        let names = environment.keys.sorted().joined(separator: ", ")
        return "RunbloomTurnStart(keys for: [\(agents)], environment: [\(names)])"
    }
}

/// The wire shape, kept out of the public type so a missing `environment` or an agent this build
/// does not know yet is handled once, here.
struct RunbloomTurnStartBody: Decodable {
    struct Key: Decodable {
        var key: String
        var identity: String
        var source: String
    }

    var agentKeys: [String: Key]?
    var environment: [String: String]?
    var githubCredentialGrant: PersonBoundGithubGrantBody?

    enum CodingKeys: String, CodingKey {
        case agentKeys = "agent_keys"
        case environment
        case githubCredentialGrant = "github_credential_grant"
    }

    /// An agent runbloom.app names that this server does not know is skipped rather than failing
    /// the turn, because runbloom.app may learn about an agent before every machine is updated.
    var start: RunbloomTurnStart {
        var keys: [AgentKind: RemoteAgentKey] = [:]
        for (name, value) in agentKeys ?? [:] {
            guard let agent = AgentKind.named(wire: name) else { continue }
            keys[agent] = RemoteAgentKey(key: value.key, identity: value.identity, source: value.source)
        }
        let remoteGrant = githubCredentialGrant?.grant.map {
            RemoteGithubCredentialGrant(token: $0.token, expiresAt: $0.expiresAt, revision: $0.revision)
        }
        return RunbloomTurnStart(agentKeys: keys, environment: environment ?? [:], githubCredentialGrant: remoteGrant)
    }
}

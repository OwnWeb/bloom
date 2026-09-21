import BloomCore
import Foundation

/// Opaque model authority returned by runbloom.app. It stays inside Bloom Runner and redacts its
/// bearer from interpolation, reflection and debug output.
public struct OpaqueModelGrant: Decodable, Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public enum Provider: String, Codable, Sendable, Hashable {
        case anthropic
        case openai
        case xai
    }

    public enum Operation: String, Codable, Sendable, Hashable {
        case anthropicMessagesStream = "anthropic_messages_stream"
        case openAIResponsesStream = "openai_responses_stream"
        case xAIResponsesStream = "xai_responses_stream"
    }

    public var version: String
    public var token: String
    public var expiresAt: Date
    public var revision: Int
    public var provider: Provider
    public var model: String
    public var operation: Operation

    enum CodingKeys: String, CodingKey {
        case version, token, revision, provider, model, operation
        case expiresAt = "expires_at"
    }

    public init(
        version: String = "opaque_model_grant_v1", token: String, expiresAt: Date,
        revision: Int, provider: Provider, model: String, operation: Operation
    ) {
        self.version = version
        self.token = token
        self.expiresAt = expiresAt
        self.revision = revision
        self.provider = provider
        self.model = model
        self.operation = operation
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        token = try values.decode(String.self, forKey: .token)
        let expires = try values.decode(String.self, forKey: .expiresAt)
        guard expires.hasSuffix("Z"), let date = PersonBoundGithubGrantBody.date(expires) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt, in: values, debugDescription: "Expected an ISO8601 UTC date."
            )
        }
        expiresAt = date
        revision = try values.decode(Int.self, forKey: .revision)
        provider = try values.decode(Provider.self, forKey: .provider)
        model = try values.decode(String.self, forKey: .model)
        operation = try values.decode(Operation.self, forKey: .operation)
    }

    public var description: String {
        "OpaqueModelGrant(provider: \(provider.rawValue), model: \(model), operation: "
            + "\(operation.rawValue), expiresAt: \(expiresAt), revision: \(revision), token: [REDACTED])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

/// What `POST .../turns/{turn}/start` hands back. Provider authority remains private to this type
/// and the local gateway which consumes it.
public struct RunbloomTurnStart: Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public var modelGrants: [AgentKind: OpaqueModelGrant]
    public var environment: [String: String]
    public var githubCredentialGrant: RemoteGithubCredentialGrant?

    public init(
        modelGrants: [AgentKind: OpaqueModelGrant], environment: [String: String],
        githubCredentialGrant: RemoteGithubCredentialGrant? = nil
    ) {
        self.modelGrants = modelGrants
        self.environment = environment
        self.githubCredentialGrant = githubCredentialGrant
    }

    public var description: String {
        let agents = modelGrants.keys.map(\.wireName).sorted().joined(separator: ", ")
        let names = environment.keys.sorted().joined(separator: ", ")
        return "RunbloomTurnStart(model grants for: [\(agents)], environment: [\(names)])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

struct RunbloomTurnStartBody: Decodable {
    var modelGrants: [String: OpaqueModelGrant]?
    var environment: [String: String]?
    var githubCredentialGrant: PersonBoundGithubGrantBody?

    enum CodingKeys: String, CodingKey {
        case modelGrants = "model_grants"
        case environment
        case githubCredentialGrant = "github_credential_grant"
    }

    var start: RunbloomTurnStart {
        var grants: [AgentKind: OpaqueModelGrant] = [:]
        for (name, value) in modelGrants ?? [:] {
            guard let agent = AgentKind.named(wire: name) else { continue }
            grants[agent] = value
        }
        let remoteGrant = githubCredentialGrant?.grant.map {
            RemoteGithubCredentialGrant(token: $0.token, expiresAt: $0.expiresAt, revision: $0.revision)
        }
        return RunbloomTurnStart(
            modelGrants: grants, environment: environment ?? [:], githubCredentialGrant: remoteGrant
        )
    }
}

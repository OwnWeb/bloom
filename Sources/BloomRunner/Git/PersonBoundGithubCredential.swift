import Foundation

/// The only operations the v2 server contract accepts. The wrapper decides this from the command,
/// never from text sent by the process asking for a credential.
public enum PersonBoundGithubOperation: String, Codable, Sendable, Hashable {
    case gitRead = "git_read"
    case gitWrite = "git_write"
    case ghRead = "gh_read"
    case ghWrite = "gh_write"

    /// How the git wrapper tells the credential helper below it what the command was. The helper
    /// is spawned by git and is only ever told `get`, so without this it knows nothing about the
    /// operation it is fetching a credential for.
    static let environmentKey = "BLOOM_PERSON_BOUND_OPERATION"
}

/// An opaque, rotating bearer from runbloom.app. It exists only in the in-memory broker.
public struct PersonBoundGithubGrant: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var token: String
    public var expiresAt: Date
    public var revision: Int

    public init(token: String, expiresAt: Date, revision: Int) {
        self.token = token
        self.expiresAt = expiresAt
        self.revision = revision
    }

    public var description: String {
        "PersonBoundGithubGrant(expiresAt: \(expiresAt), revision: \(revision), token: [REDACTED])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

public struct PersonBoundGithubCredentials: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var token: String
    public var expiresAt: Date
    public var username: String
    public var nextGrant: PersonBoundGithubGrant

    public init(token: String, expiresAt: Date, username: String, nextGrant: PersonBoundGithubGrant) {
        self.token = token
        self.expiresAt = expiresAt
        self.username = username
        self.nextGrant = nextGrant
    }

    public var description: String {
        "PersonBoundGithubCredentials(username: \(username), expiresAt: \(expiresAt), nextGrant: \(nextGrant))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

struct PersonBoundGithubGrantBody: Decodable {
    var token: String
    var expiresAt: String
    var revision: Int

    enum CodingKeys: String, CodingKey {
        case token, revision
        case expiresAt = "expires_at"
    }

    var grant: PersonBoundGithubGrant? {
        guard token.count == 64, revision > 0, let expiry = Self.date(expiresAt) else { return nil }
        return PersonBoundGithubGrant(token: token, expiresAt: expiry, revision: revision)
    }

    /// Laravel may write microseconds, which Foundation's ISO 8601 parser does not read
    /// consistently on every supported platform.
    static func date(_ text: String) -> Date? {
        let plain = Date.ISO8601FormatStyle()
        guard let dot = text.firstIndex(of: ".") else { return try? plain.parse(text) }
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let whole = String(text[..<dot]) + String(text[digits.endIndex...])
        guard let seconds = try? plain.parse(whole) else { return nil }
        return seconds.addingTimeInterval(Double("0." + digits) ?? 0)
    }
}

struct PersonBoundGithubCredentialsBody: Decodable {
    struct Credential: Decodable {
        var username: String
        var token: String
        var expiresAt: String

        enum CodingKeys: String, CodingKey {
            case username, token
            case expiresAt = "expires_at"
        }
    }

    var credential: Credential
    var nextGrant: PersonBoundGithubGrantBody

    enum CodingKeys: String, CodingKey {
        case credential
        case nextGrant = "next_grant"
    }

    var issued: PersonBoundGithubCredentials? {
        guard !credential.token.isEmpty,
              let expiry = PersonBoundGithubGrantBody.date(credential.expiresAt),
              let next = nextGrant.grant else { return nil }
        return PersonBoundGithubCredentials(
            token: credential.token, expiresAt: expiry, username: credential.username, nextGrant: next
        )
    }
}

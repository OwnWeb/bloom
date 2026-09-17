import BloomCore
import Foundation

/// What a token issued by runbloom.app is for. The verifier is always told which one it expects,
/// so a token is never accepted for a purpose it was not signed for.
public enum TokenUse: String, Sendable, Hashable, CaseIterable {
    /// A person using the workspace: five minutes, carries their name and abilities.
    case session
    /// Opening a preview in a browser: one minute, and good for one request.
    case preview
    /// runbloom.app itself calling the machine: one minute, and good for one request.
    case control

    /// The longest `exp - iat` runbloom.app issues for this use. A longer one is refused even when
    /// it verifies, so a signing mistake on runbloom.app cannot mint a token that lasts a day.
    public var maximumLifetime: TimeInterval {
        switch self {
        case .session: 300
        case .preview, .control: 60
        }
    }

    /// The abilities this use can grant. Anything else in the claim is dropped, which caps what a
    /// preview link or a control call could do if runbloom.app ever put too much in one.
    var grantableAbilities: Set<String> {
        switch self {
        case .session: ["view", "prompt", "terminal", "files", "preview", "share"]
        case .preview: ["preview"]
        case .control: ["admin"]
        }
    }

    /// A preview link and a control call are each good for one request, so their `jti` is
    /// remembered until they expire.
    var isSingleUse: Bool { self != .session }
}

/// A token that has been verified: its signature, issuer, audience, use and lifetime all checked.
/// Nothing unverified is ever held in one of these.
public struct WorkspaceToken: Sendable, Hashable {
    public var use: TokenUse
    /// A user id, `share:<share id>` for a preview opened from a share, or `control`.
    public var subject: String
    /// Session tokens only.
    public var name: String?
    /// Session tokens only.
    public var team: String?
    public var abilities: Set<String>
    public var issuedAt: Date
    public var expiresAt: Date
    /// Named after the claim rather than `id`, because it is runbloom.app's identifier for the
    /// token and nothing in Bloom's own database.
    public var jti: String
    /// The `kid` of the key that signed it.
    public var signingKey: String

    public init(
        use: TokenUse,
        subject: String,
        name: String? = nil,
        team: String? = nil,
        abilities: Set<String>,
        issuedAt: Date,
        expiresAt: Date,
        jti: String,
        signingKey: String
    ) {
        self.use = use
        self.subject = subject
        self.name = name
        self.team = team
        self.abilities = abilities
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.jti = jti
        self.signingKey = signingKey
    }

    /// The person a session token names, as a queued prompt records them. Nil for a preview or a
    /// control token, which are not somebody writing in the workspace.
    public var author: MessageAuthor? {
        guard use == .session else { return nil }
        return MessageAuthor(userID: subject, name: name ?? subject)
    }

    /// A preview opened through a share link rather than by a member of the team.
    public var isShare: Bool { subject.hasPrefix("share:") }

    /// `token` is the raw token this was verified from. Only a session token is handed on,
    /// because registering a turn with runbloom.app passes the prompter's own session token and
    /// nothing else would be accepted there.
    public func caller(token: String) -> RemoteCaller {
        RemoteCaller(author: author, abilities: abilities, sessionToken: use == .session ? token : nil)
    }
}

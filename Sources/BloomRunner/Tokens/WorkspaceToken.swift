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
    /// Session tokens only. **May be absent or empty**: not everybody has a display name, and a
    /// machine that refused them would be a machine they could not use.
    public var name: String?
    /// Session tokens only, and the thing a person recognises when there is no name.
    public var email: String?
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
    /// The workspace an agent was running in when runbloom.app minted this for its person, from the
    /// standard `act` claim. Session tokens only; nil on a person's own. See `RemoteCaller.agentOrigin`.
    public var actor: String?

    public init(
        use: TokenUse,
        subject: String,
        name: String? = nil,
        email: String? = nil,
        team: String? = nil,
        abilities: Set<String>,
        issuedAt: Date,
        expiresAt: Date,
        jti: String,
        signingKey: String,
        actor: String? = nil
    ) {
        self.actor = actor
        self.use = use
        self.subject = subject
        self.name = name
        self.email = email
        self.team = team
        self.abilities = abilities
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.jti = jti
        self.signingKey = signingKey
    }

    /// The person a session token names, as a queued prompt records them. Nil for a preview or a
    /// control token, which are not somebody writing in the workspace.
    /// **An empty name is not a missing one, and both have to be handled.** This used to read
    /// `name ?? subject`, which catches a claim that is absent and steps aside for one that is
    /// present and empty, putting an empty string on the wire that draws a label indistinguishable
    /// from no label at all. In a shared workspace an unlabelled message reads as the reader's own.
    ///
    /// The email is carried rather than folded into the name; see `AuthorRecord.label` for what a
    /// client draws from the two.
    public var author: MessageAuthor? {
        guard use == .session else { return nil }
        let stated = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MessageAuthor(userID: subject, name: stated, email: address.isEmpty ? nil : address)
    }

    /// Refuses a token minted for an agent in another workspace, at a door that is not the RPC one.
    /// Such a token may send a message and nothing else (see `RemoteCaller.agentMayRun`), so it
    /// does not watch the event stream and does not open a terminal.
    public func refuseIfMintedForAnAgent() throws {
        guard actor == nil else {
            throw RemoteFailure(.missingAbility, "A token minted for an agent in another workspace can only send a message here.")
        }
    }

    /// A preview opened through a share link rather than by a member of the team.
    public var isShare: Bool { subject.hasPrefix("share:") }

    /// `token` is the raw token this was verified from. Only a session token is handed on,
    /// because registering a turn with runbloom.app passes the prompter's own session token and
    /// nothing else would be accepted there.
    public func caller(token: String) -> RemoteCaller {
        RemoteCaller(author: author, abilities: abilities, sessionToken: use == .session ? token : nil,
                     agentOrigin: use == .session ? actor : nil)
    }
}

import BloomCore
import BloomProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Verifies runbloom.app's workspace tokens offline, against its published keys.
///
/// The issuer and the workspace id are this machine's configuration and never read from a token,
/// so a validly signed token for another workspace is as useless here as a forged one. The caller
/// always says which use it expects: a session token that also opened previews would turn a
/// five minute credential into a shareable link, and a user token accepted as a control call would
/// be a person acting as runbloom.app.
///
/// Every refusal is `unauthenticated` except an expired token, which is `tokenExpired` so a client
/// knows to fetch a fresh one rather than give up. No message ever quotes the token or a claim
/// from it, because messages end up in logs and in front of people.
public actor TokenVerifier {
    /// Allowed either way on `iat` and `exp`, because runbloom.app's clock and this machine's are
    /// not the same clock.
    public static let clockSkew: TimeInterval = 30
    /// How many single-use tokens are remembered at once. With a sixty second lifetime this is far
    /// above anything honest, so reaching it means a flood, and the answer to a flood is to refuse
    /// rather than forget, since forgetting is what would let a replay through.
    public static let replayCapacity = 10_000

    private let issuer: String
    private let audience: String
    private let keys: KeySet
    private let now: @Sendable () -> Date
    /// People and share links that lost access. Checked here so every route refuses their tokens
    /// alike, rather than each route remembering to.
    public nonisolated let revocations: Revocations

    /// `use:jti` of every single-use token accepted and not yet expired, with when it can be
    /// forgotten.
    private var used: [String: Date] = [:]

    /// `revocations` nil keeps them in memory, on this verifier's clock.
    public init(issuer: String, workspaceID: String, keys: KeySet, revocations: Revocations? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.issuer = issuer
        self.audience = "bloom-workspace:\(workspaceID)"
        self.keys = keys
        self.revocations = revocations ?? Revocations(now: now)
        self.now = now
    }

    public func verify(_ token: String, as use: TokenUse) async throws -> WorkspaceToken {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Base64URL.decode(parts[0]),
              let payloadData = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2])
        else { throw Self.refusal("This is not a workspace token.") }

        guard let header = try? JSONDecoder().decode(Header.self, from: headerData) else {
            throw Self.refusal("This is not a workspace token.")
        }
        // `alg` is checked against the one algorithm this server verifies, never used to choose
        // one, which is the whole of the "alg: none" family of mistakes.
        guard header.alg == "EdDSA", header.typ == nil || header.typ == "JWT", header.crit == nil,
              let kid = header.keyName, !kid.isEmpty
        else { throw Self.refusal("This workspace token is not signed the way runbloom.app signs.") }

        guard let key = await keys.key(for: kid) else {
            throw Self.refusal("This workspace token was not signed by a key runbloom.app publishes.")
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.isValidSignature(signature, for: signingInput) else {
            throw Self.refusal("This workspace token's signature does not verify.")
        }

        // Everything below reads claims that are now known to be runbloom.app's.
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payloadData) else {
            throw Self.refusal("This workspace token's claims are not readable.")
        }
        guard claims.iss == issuer else { throw Self.refusal("This workspace token was issued by someone else.") }
        guard claims.aud == audience else { throw Self.refusal("This workspace token is for another workspace.") }
        guard claims.tokenUse == use.rawValue else {
            throw Self.refusal("This workspace token cannot be used for this.")
        }
        // A list naming an ability twice is not one runbloom.app writes, and refusing it keeps two
        // readers of the same token from ever disagreeing about what it grants.
        if let listed = claims.abilities, Set(listed).count != listed.count {
            throw Self.refusal("This workspace token's claims are not readable.")
        }
        let abilities = Set(claims.abilities ?? [])
        if abilities.contains("admin"), use != .control {
            throw Self.refusal("This workspace token claims an ability it cannot hold.")
        }
        guard let subject = claims.sub, !subject.isEmpty, let jti = claims.jti, !jti.isEmpty,
              let iat = claims.iat, let exp = claims.exp, iat.isFinite, exp.isFinite
        else { throw Self.refusal("This workspace token is missing a claim.") }
        switch use {
        case .session:
            // **A name is not required and used to be.** A person runbloom.app has no display name
            // for was refused the workspace outright, which is a worse answer than an unlabelled
            // message: the identity that matters is the subject, which is checked above, and what
            // a client draws is a presentation question answered by `AuthorRecord.label`.
            break
        case .preview:
            break
        case .control:
            guard subject == "control" else { throw Self.refusal("This workspace token cannot be used for this.") }
        }

        guard exp > iat, exp - iat <= use.maximumLifetime else {
            throw Self.refusal("This workspace token lasts longer than runbloom.app issues them for.")
        }
        let moment = now()
        let issuedAt = Date(timeIntervalSince1970: iat)
        let expiresAt = Date(timeIntervalSince1970: exp)
        guard issuedAt <= moment.addingTimeInterval(Self.clockSkew) else {
            throw Self.refusal("This workspace token was issued in the future.")
        }
        guard expiresAt.addingTimeInterval(Self.clockSkew) > moment else {
            throw RemoteFailure(.tokenExpired, "This workspace token has expired.")
        }

        if use != .control, await revocations.isRevoked(subject, issuedAt: issuedAt) {
            throw RemoteFailure(.unauthenticated, "Your access to this Bloom Cloud workspace was removed.")
        }

        if use.isSingleUse {
            try remember("\(use.rawValue):\(jti)", until: expiresAt.addingTimeInterval(Self.clockSkew), at: moment)
        }

        return WorkspaceToken(
            use: use,
            subject: subject,
            name: use == .session ? claims.name : nil,
            email: use == .session ? claims.email : nil,
            team: use == .session ? claims.team : nil,
            abilities: abilities.intersection(use.grantableAbilities),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            jti: jti,
            signingKey: kid
        )
    }

    /// Checked and recorded with no suspension in between, so two requests racing with the same
    /// preview link cannot both see it unused.
    private func remember(_ key: String, until forgettable: Date, at moment: Date) throws {
        if let seen = used[key], seen > moment {
            throw Self.refusal("This workspace token has already been used.")
        }
        if used.count >= Self.replayCapacity {
            used = used.filter { $0.value > moment }
        }
        guard used.count < Self.replayCapacity else {
            throw Self.refusal("Too many workspace tokens have been used in the last minute.")
        }
        used[key] = forgettable
    }

    private static func refusal(_ message: String) -> RemoteFailure {
        RemoteFailure(.unauthenticated, message)
    }

    private struct Header: Decodable {
        var alg: String?
        var typ: String?
        var keyName: String?
        /// Only its presence matters: a critical extension this server does not know means the
        /// token asks for handling it will not get, so it is refused.
        var crit: [String]?

        enum CodingKeys: String, CodingKey {
            case alg, typ, crit
            case keyName = "kid"
        }
    }

    private struct Claims: Decodable {
        var iss: String?
        var aud: String?
        var sub: String?
        var name: String?
        var email: String?
        var team: String?
        var tokenUse: String?
        var abilities: [String]?
        var iat: Double?
        var exp: Double?
        var jti: String?

        enum CodingKeys: String, CodingKey {
            case iss, aud, sub, name, email, team, abilities, iat, exp, jti
            case tokenUse = "token_use"
        }
    }
}

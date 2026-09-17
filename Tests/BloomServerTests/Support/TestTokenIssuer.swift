@testable import BloomServer
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Plays runbloom.app's part: holds an Ed25519 key, publishes it as a JWKS, and signs workspace
/// tokens in exactly the format runbloom.app issues.
///
/// Every claim can be replaced or removed, and the header too, so a test can forge the one thing
/// it is about and leave everything else valid. A test that forged two things at once could pass
/// because of the wrong one.
///
///     let issuer = TestTokenIssuer()
///     let verifier = issuer.verifier(clock: clock)
///     let token = issuer.session(issuedAt: clock.now)
struct TestTokenIssuer: Sendable {
    static let defaultIssuer = "https://runbloom.app"
    static let defaultWorkspaceID = "01k5a7d3v1x0m8n2q4r6s9t0wy"
    static let defaultUserID = "01k5a7c2b0z9y8x7w6v5t4s3rq"

    let issuer: String
    let workspaceID: String
    let privateKey: Curve25519.Signing.PrivateKey
    /// The RFC 7638 thumbprint, which is what runbloom.app uses, unless a test named its own.
    let keyID: String

    init(issuer: String = defaultIssuer, workspaceID: String = defaultWorkspaceID, keyID: String? = nil) {
        self.issuer = issuer
        self.workspaceID = workspaceID
        privateKey = Curve25519.Signing.PrivateKey()
        self.keyID = keyID ?? JWKThumbprint.ed25519(x: Base64URL.encode(privateKey.publicKey.rawRepresentation))
    }

    var audience: String { "bloom-workspace:\(workspaceID)" }

    /// This key as one entry of a JWKS.
    var jwk: [String: String] {
        [
            "kty": "OKP",
            "crv": "Ed25519",
            "x": Base64URL.encode(privateKey.publicKey.rawRepresentation),
            "kid": keyID,
            "alg": "EdDSA",
            "use": "sig",
        ]
    }

    /// A JWKS publishing this key alone.
    var jwks: Data { Self.jwks([self]) }

    /// A JWKS publishing several keys, as runbloom.app does during a rotation.
    static func jwks(_ issuers: [TestTokenIssuer]) -> Data {
        json(["keys": issuers.map(\.jwk)])
    }

    /// A key set that always serves this key and never touches the network.
    func keySet(clock: TestClock? = nil) -> KeySet {
        let body = jwks
        let fetch: @Sendable () async throws -> KeySetFetch = { KeySetFetch.keys(body) }
        guard let clock else { return KeySet(fetch: fetch) }
        return KeySet(fetch: fetch, now: clock.reading)
    }

    /// A verifier configured for this issuer and workspace, reading `clock`.
    func verifier(clock: TestClock) -> TokenVerifier {
        TokenVerifier(issuer: issuer, workspaceID: workspaceID, keys: keySet(clock: clock), now: clock.reading)
    }

    // MARK: Tokens

    func session(
        userID: String = defaultUserID,
        name: String = "Freek",
        team: String = "01k5a7b1a9y8x7w6v5t4s3r2qp",
        abilities: [String] = ["view", "prompt", "terminal", "files", "preview", "share"],
        issuedAt: Date = Date(),
        lifetime: TimeInterval = 300,
        overrides: [String: Any] = [:],
        removing: Set<String> = []
    ) -> String {
        var claims = base(use: .session, subject: userID, abilities: abilities, issuedAt: issuedAt, lifetime: lifetime)
        claims["name"] = name
        claims["team"] = team
        return sign(claims: claims, overrides: overrides, removing: removing)
    }

    /// `subject` is a user id, or `share:<share id>` for a preview opened from a share link.
    func preview(
        subject: String = defaultUserID,
        issuedAt: Date = Date(),
        lifetime: TimeInterval = 60,
        overrides: [String: Any] = [:],
        removing: Set<String> = []
    ) -> String {
        let claims = base(use: .preview, subject: subject, abilities: ["preview"], issuedAt: issuedAt, lifetime: lifetime)
        return sign(claims: claims, overrides: overrides, removing: removing)
    }

    func control(
        issuedAt: Date = Date(),
        lifetime: TimeInterval = 60,
        overrides: [String: Any] = [:],
        removing: Set<String> = []
    ) -> String {
        let claims = base(use: .control, subject: "control", abilities: ["admin"], issuedAt: issuedAt, lifetime: lifetime)
        return sign(claims: claims, overrides: overrides, removing: removing)
    }

    /// Signs any claims under any header. `header` replaces the members it names in the header
    /// runbloom.app sends, and `removingHeader` drops members from it.
    func sign(
        claims: [String: Any],
        overrides: [String: Any] = [:],
        removing: Set<String> = [],
        header: [String: Any] = [:],
        removingHeader: Set<String> = []
    ) -> String {
        var payload = claims.merging(overrides) { _, override in override }
        for name in removing { payload[name] = nil }
        var protected: [String: Any] = ["alg": "EdDSA", "typ": "JWT", "kid": keyID]
        protected.merge(header) { _, override in override }
        for name in removingHeader { protected[name] = nil }
        let signingInput = Base64URL.encode(Self.json(protected)) + "." + Base64URL.encode(Self.json(payload))
        // Force-tried because signing with a key this helper generated has no way to fail.
        // swiftlint:disable:next force_try
        let signature = try! privateKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(signature)
    }

    private func base(use: TokenUse, subject: String, abilities: [String], issuedAt: Date, lifetime: TimeInterval) -> [String: Any] {
        let iat = Int(issuedAt.timeIntervalSince1970)
        return [
            "iss": issuer,
            "aud": audience,
            "sub": subject,
            "token_use": use.rawValue,
            "abilities": abilities,
            "iat": iat,
            "exp": iat + Int(lifetime),
            "jti": UUID().uuidString.lowercased(),
        ]
    }

    private static func json(_ object: Any) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

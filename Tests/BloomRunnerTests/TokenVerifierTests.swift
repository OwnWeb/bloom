import BloomCore
import BloomProtocol
@testable import BloomRunner
import Foundation
import Testing

struct TokenVerifierTests {
    let issuer = TestTokenIssuer()
    let clock = TestClock()

    // MARK: The replay cache

    /// L3 in the review of 19 September 2026, and the replay cap it rests on: a flood of preview
    /// links fills the preview table and nothing else, so `revoke` still gets through.
    @Test func aFullPreviewCacheRefusesPreviewsAndNotControl() async throws {
        let verifier = issuer.verifier(clock: clock)
        let first = issuer.preview(issuedAt: clock.now)
        _ = try await verifier.verify(first, as: .preview)
        await #expect(throws: RemoteFailure.self, "a preview link is good for one request") {
            _ = try await verifier.verify(first, as: .preview)
        }
        for _ in 1..<TokenVerifier.replayCapacity {
            _ = try await verifier.verify(issuer.preview(issuedAt: clock.now), as: .preview)
        }
        await #expect(throws: RemoteFailure.self, "at the cap a new preview is refused rather than an old one forgotten") {
            _ = try await verifier.verify(issuer.preview(issuedAt: clock.now), as: .preview)
        }
        let control = try await verifier.verify(issuer.control(issuedAt: clock.now), as: .control)
        #expect(control.use == .control)
    }

    // MARK: Accepted

    @Test func aSessionTokenVerifiesWithItsClaims() async throws {
        let raw = issuer.session(name: "Freek", abilities: ["view", "prompt"], issuedAt: clock.now)
        let token = try await issuer.verifier(clock: clock).verify(raw, as: .session)

        #expect(token.use == .session)
        #expect(token.subject == TestTokenIssuer.defaultUserID)
        #expect(token.name == "Freek")
        #expect(token.team != nil)
        #expect(token.abilities == ["view", "prompt"])
        #expect(token.expiresAt.timeIntervalSince(token.issuedAt) == 300)
        #expect(token.signingKey == issuer.keyID)
        #expect(token.author == MessageAuthor(userID: TestTokenIssuer.defaultUserID, name: "Freek"))
        #expect(!token.isShare)

        let caller = token.caller(token: raw)
        #expect(caller.author == token.author)
        #expect(caller.abilities == ["view", "prompt"])
        #expect(caller.sessionToken == raw)
    }

    @Test func aPreviewTokenVerifiesAndCarriesNoAuthor() async throws {
        let raw = issuer.preview(subject: "share:01k5a7e4f5g6h7j8k9m0n1p2q3", issuedAt: clock.now)
        let token = try await issuer.verifier(clock: clock).verify(raw, as: .preview)

        #expect(token.use == .preview)
        #expect(token.abilities == ["preview"])
        #expect(token.isShare)
        #expect(token.author == nil)
        #expect(token.caller(token: raw).sessionToken == nil)
    }

    @Test func aControlTokenVerifiesWithTheAdminAbility() async throws {
        let token = try await issuer.verifier(clock: clock).verify(issuer.control(issuedAt: clock.now), as: .control)

        #expect(token.use == .control)
        #expect(token.subject == "control")
        #expect(token.abilities == ["admin"])
        #expect(token.author == nil)
    }

    @Test func unknownAbilitiesAreIgnored() async throws {
        let raw = issuer.session(abilities: ["view", "time_travel"], issuedAt: clock.now)
        let token = try await issuer.verifier(clock: clock).verify(raw, as: .session)
        #expect(token.abilities == ["view"])
    }

    @Test func aTokenIssuedAMomentAheadOfThisClockIsAccepted() async throws {
        let raw = issuer.session(issuedAt: clock.now.addingTimeInterval(20))
        _ = try await issuer.verifier(clock: clock).verify(raw, as: .session)
    }

    // MARK: Use

    @Test(arguments: [
        (TokenUse.session, TokenUse.preview), (.session, .control),
        (.preview, .session), (.preview, .control),
        (.control, .session), (.control, .preview),
    ])
    func aTokenIsRefusedWhereAnotherUseIsExpected(signed: TokenUse, expected: TokenUse) async {
        let raw = switch signed {
        case .session: issuer.session(issuedAt: clock.now)
        case .preview: issuer.preview(issuedAt: clock.now)
        case .control: issuer.control(issuedAt: clock.now)
        }
        await expectRefused(raw, as: expected)
    }

    @Test func aTokenWithNoUseIsRefused() async {
        await expectRefused(issuer.session(issuedAt: clock.now, removing: ["token_use"]), as: .session)
    }

    @Test func adminIsRefusedInASessionToken() async {
        await expectRefused(issuer.session(abilities: ["view", "admin"], issuedAt: clock.now), as: .session)
    }

    @Test func adminIsRefusedInAPreviewToken() async {
        await expectRefused(issuer.preview(issuedAt: clock.now, overrides: ["abilities": ["preview", "admin"]]), as: .preview)
    }

    @Test func aControlTokenForSomebodyOtherThanControlIsRefused() async {
        await expectRefused(issuer.control(issuedAt: clock.now, overrides: ["sub": TestTokenIssuer.defaultUserID]), as: .control)
    }

    /// **This used to be refused and is now accepted, deliberately.** Turning away everybody
    /// runbloom.app has no display name for is a worse answer than an unlabelled message: the
    /// identity that matters is the subject, and what a client draws is a presentation question
    /// `AuthorRecord.label` answers from the name and the address together.
    @Test func aSessionTokenWithoutANameIsAccepted() async throws {
        let verifier = issuer.verifier(clock: clock)
        let token = try await verifier.verify(issuer.session(issuedAt: clock.now, removing: ["name"]), as: .session)

        #expect(token.author?.name == "")
        #expect(token.author?.userID == TestTokenIssuer.defaultUserID)
    }

    /// runbloom.app's standard actor claim, written when it mints a token for an agent in another
    /// workspace. Read, so the message is labelled from something signed.
    @Test func theActorClaimIsReadAndAPersonsOwnTokenHasNone() async throws {
        let verifier = issuer.verifier(clock: clock)
        let minted = try await verifier.verify(issuer.session(issuedAt: clock.now, overrides: [
            "act": ["sub": "bloom-workspace:01k5origin", "turn": "01jturn"],
        ]), as: .session)
        #expect(minted.actor == "bloom-workspace:01k5origin")
        #expect(minted.caller(token: "t").agentOrigin == "bloom-workspace:01k5origin")
        let own = try await verifier.verify(issuer.session(issuedAt: clock.now), as: .session)
        #expect(own.actor == nil)
    }

    @Test(arguments: ["sub", "jti", "iat", "exp", "iss", "aud"])
    func aTokenMissingARequiredClaimIsRefused(claim: String) async {
        await expectRefused(issuer.session(issuedAt: clock.now, removing: [claim]), as: .session)
    }

    // MARK: Issuer and audience

    @Test func aTokenFromAnotherIssuerIsRefused() async {
        await expectRefused(issuer.session(issuedAt: clock.now, overrides: ["iss": "https://runbloom.app/"]), as: .session)
    }

    @Test func aTokenForAnotherWorkspaceIsRefused() async {
        let other = "bloom-workspace:01k5a7zzzzzzzzzzzzzzzzzzzz"
        await expectRefused(issuer.session(issuedAt: clock.now, overrides: ["aud": other]), as: .session)
    }

    @Test func anAudienceAsAListIsRefused() async {
        await expectRefused(issuer.session(issuedAt: clock.now, overrides: ["aud": [issuer.audience]]), as: .session)
    }

    // MARK: Time

    @Test func anExpiredTokenIsRefusedAsExpired() async {
        let raw = issuer.session(issuedAt: clock.now.addingTimeInterval(-400))
        await expectRefused(raw, as: .session, code: .tokenExpired)
    }

    @Test func expiryAllowsThirtySecondsOfSkewAndNoMore() async throws {
        let verifier = issuer.verifier(clock: clock)
        let raw = issuer.session(issuedAt: clock.now.addingTimeInterval(-300))
        clock.advance(by: 29)
        _ = try await verifier.verify(raw, as: .session)
        clock.advance(by: 1)
        await expectRefused(raw, as: .session, code: .tokenExpired, verifier: verifier)
    }

    @Test func aTokenIssuedInTheFutureIsRefused() async {
        await expectRefused(issuer.session(issuedAt: clock.now.addingTimeInterval(31)), as: .session)
    }

    @Test(arguments: [(TokenUse.session, 301.0), (.preview, 61.0), (.control, 61.0)])
    func aTokenLastingLongerThanItsUseAllowsIsRefused(use: TokenUse, lifetime: TimeInterval) async {
        let raw = switch use {
        case .session: issuer.session(issuedAt: clock.now, lifetime: lifetime)
        case .preview: issuer.preview(issuedAt: clock.now, lifetime: lifetime)
        case .control: issuer.control(issuedAt: clock.now, lifetime: lifetime)
        }
        await expectRefused(raw, as: use)
    }

    @Test func aTokenThatExpiresBeforeItIsIssuedIsRefused() async {
        await expectRefused(issuer.session(issuedAt: clock.now, lifetime: -10), as: .session)
    }

    // MARK: Signature and shape

    @Test func aTamperedPayloadIsRefused() async {
        let parts = issuer.session(abilities: ["view"], issuedAt: clock.now).split(separator: ".").map(String.init)
        let other = issuer.session(abilities: ["view", "prompt", "terminal"], issuedAt: clock.now).split(separator: ".").map(String.init)
        await expectRefused([parts[0], other[1], parts[2]].joined(separator: "."), as: .session)
    }

    @Test func aTamperedSignatureIsRefused() async {
        var parts = issuer.session(issuedAt: clock.now).split(separator: ".").map(String.init)
        var signature = Base64URL.decode(parts[2]) ?? Data()
        signature[0] ^= 0x01
        parts[2] = Base64URL.encode(signature)
        await expectRefused(parts.joined(separator: "."), as: .session)
    }

    @Test func aTokenSignedByAKeyNobodyPublishedIsRefused() async {
        let impostor = TestTokenIssuer(keyID: issuer.keyID)
        await expectRefused(impostor.session(issuedAt: clock.now), as: .session)
    }

    @Test func anotherAlgorithmIsRefused() async {
        await expectRefused(issuer.session(issuedAt: clock.now).replacingHeader(with: issuer, ["alg": "none"]), as: .session)
        await expectRefused(issuer.sign(claims: sessionClaims(), header: ["alg": "HS256"]), as: .session)
    }

    @Test func aTokenWithACriticalExtensionIsRefused() async {
        await expectRefused(issuer.sign(claims: sessionClaims(), header: ["crit": ["exp"]]), as: .session)
    }

    @Test func aTokenWithNoKeyIDIsRefused() async {
        await expectRefused(issuer.sign(claims: sessionClaims(), removingHeader: ["kid"]), as: .session)
    }

    @Test(arguments: ["", "abc", "a.b", "a.b.c.d", "e30.e30.", "!!!.e30.e30"])
    func somethingThatIsNotATokenIsRefused(text: String) async {
        await expectRefused(text, as: .session)
    }

    @Test func aRefusalNeverQuotesTheToken() async {
        let raw = issuer.session(issuedAt: clock.now, overrides: ["aud": "bloom-workspace:elsewhere"])
        do {
            _ = try await issuer.verifier(clock: clock).verify(raw, as: .session)
            Issue.record("expected a refusal")
        } catch let failure as RemoteFailure {
            #expect(!failure.message.contains(raw.prefix(20)))
            #expect(!failure.message.contains("elsewhere"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: Replay

    @Test func abilitiesNamedTwiceAreRefused() async {
        let raw = issuer.session(abilities: ["view", "view"], issuedAt: clock.now)
        await #expect(throws: RemoteFailure.self) { try await issuer.verifier(clock: clock).verify(raw, as: .session) }
    }

    @Test func aTokenIssuedBeforeItsSubjectWasRevokedIsRefusedAndOneIssuedLaterIsNot() async throws {
        let verifier = issuer.verifier(clock: clock)
        let before = issuer.session(issuedAt: clock.now)
        _ = try await verifier.verify(before, as: .session)
        await verifier.revocations.revoke(TestTokenIssuer.defaultUserID)
        await #expect(throws: RemoteFailure.self) { try await verifier.verify(before, as: .session) }
        let share = issuer.preview(subject: "share:01k5a7e4f5g6h7j8k9m0n1p2q3", issuedAt: clock.now)
        await verifier.revocations.revoke("share:01k5a7e4f5g6h7j8k9m0n1p2q3")
        await #expect(throws: RemoteFailure.self) { try await verifier.verify(share, as: .preview) }

        clock.advance(by: TokenVerifier.clockSkew + 1)
        _ = try await verifier.verify(issuer.session(issuedAt: clock.now), as: .session)
    }

    @Test func aPreviewTokenIsGoodForOneUse() async throws {
        let verifier = issuer.verifier(clock: clock)
        let raw = issuer.preview(issuedAt: clock.now)
        _ = try await verifier.verify(raw, as: .preview)
        await expectRefused(raw, as: .preview, verifier: verifier)
    }

    @Test func aControlTokenIsGoodForOneUse() async throws {
        let verifier = issuer.verifier(clock: clock)
        let raw = issuer.control(issuedAt: clock.now)
        _ = try await verifier.verify(raw, as: .control)
        await expectRefused(raw, as: .control, verifier: verifier)
    }

    @Test func aSessionTokenCanBeUsedRepeatedly() async throws {
        let verifier = issuer.verifier(clock: clock)
        let raw = issuer.session(issuedAt: clock.now)
        _ = try await verifier.verify(raw, as: .session)
        _ = try await verifier.verify(raw, as: .session)
    }

    @Test func aRefusedPreviewTokenDoesNotUseItUp() async throws {
        let verifier = issuer.verifier(clock: clock)
        let raw = issuer.preview(issuedAt: clock.now)
        await expectRefused(raw, as: .control, verifier: verifier)
        _ = try await verifier.verify(raw, as: .preview)
    }

    @Test func aReplayedJTIUnderANewSignatureIsStillRefused() async throws {
        let verifier = issuer.verifier(clock: clock)
        let first = issuer.control(issuedAt: clock.now, overrides: ["jti": "one"])
        let second = issuer.control(issuedAt: clock.now.addingTimeInterval(-1), overrides: ["jti": "one"])
        _ = try await verifier.verify(first, as: .control)
        await expectRefused(second, as: .control, verifier: verifier)
    }

    // MARK: Helpers

    private func sessionClaims() -> [String: Any] {
        let iat = Int(clock.now.timeIntervalSince1970)
        return [
            "iss": issuer.issuer, "aud": issuer.audience, "sub": TestTokenIssuer.defaultUserID, "name": "Freek",
            "team": "t", "token_use": "session", "abilities": ["view"], "iat": iat, "exp": iat + 300, "jti": "j",
        ]
    }

    private func expectRefused(
        _ raw: String,
        as use: TokenUse,
        code: WireErrorCode = .unauthenticated,
        verifier: TokenVerifier? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let verifier = verifier ?? issuer.verifier(clock: clock)
        do {
            _ = try await verifier.verify(raw, as: use)
            Issue.record("expected a refusal", sourceLocation: sourceLocation)
        } catch let failure as RemoteFailure {
            #expect(failure.code == code, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
        }
    }
}

private extension String {
    /// The same token with a header this issuer did not sign, keeping the original signature.
    func replacingHeader(with issuer: TestTokenIssuer, _ header: [String: String]) -> String {
        var parts = split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var members: [String: String] = ["typ": "JWT", "kid": issuer.keyID]
        members.merge(header) { _, new in new }
        let data = (try? JSONSerialization.data(withJSONObject: members, options: [.sortedKeys])) ?? Data()
        parts[0] = Base64URL.encode(data)
        return parts.joined(separator: ".")
    }
}

/// Who a message is from, which a shared workspace draws above the bubble.
@Suite("The author a session token names")
struct TokenAuthorTests {
    private func token(name: String?, email: String? = nil) -> WorkspaceToken {
        WorkspaceToken(use: .session, subject: "user-1", name: name, email: email, abilities: ["prompt"],
                       issuedAt: .init(), expiresAt: .init().addingTimeInterval(300), jti: "jti-1", signingKey: "kid-1")
    }

    /// The bug this exists for: `name ?? subject` catches a claim that is absent and steps aside
    /// for one that is present and empty, putting an empty label on a message in a shared
    /// workspace, where it reads as the reader's own.
    @Test("an empty name is carried as empty rather than as a user id, and the email comes with it")
    func emptyName() throws {
        let author = try #require(token(name: "", email: "technical@example.com").author)

        #expect(author.name.isEmpty)
        #expect(author.email == "technical@example.com")
        #expect(author.record.label == "technical@example.com")
    }

    @Test("a name wins over an address when there is one")
    func nameWins() throws {
        let author = try #require(token(name: "Freek", email: "freek@example.com").author)

        #expect(author.record.label == "Freek")
        #expect(author.email == "freek@example.com", "the address still travels, because mentions match on it")
    }

    /// Neither, which is all a share-link guest has. A client says "somebody" rather than nothing.
    @Test("no name and no address still draws something")
    func neither() throws {
        let author = try #require(token(name: nil).author)

        #expect(author.userID == "user-1")
        #expect(author.email == nil)
        #expect(author.record.label == "somebody")
    }

    @Test("a whitespace name is an empty one")
    func whitespaceIsEmpty() throws {
        #expect(try #require(token(name: "   ", email: " a@b.test ").author).record.label == "a@b.test")
    }
}

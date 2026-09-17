@testable import BloomServer
import Foundation
import Synchronization
import Testing

struct KeySetTests {
    let clock = TestClock()

    @Test func aPublishedKeyIsFoundAndCached() async {
        let issuer = TestTokenIssuer()
        let server = FakeJWKS(.keys(issuer.jwks))
        let keys = server.keySet(clock: clock)

        #expect(await keys.key(for: issuer.keyID) != nil)
        #expect(await keys.key(for: issuer.keyID) != nil)
        #expect(server.fetches == 1)
    }

    @Test func anUnknownKeyIDRefetchesOnceAMinuteAtMost() async {
        let issuer = TestTokenIssuer()
        let server = FakeJWKS(.keys(issuer.jwks))
        let keys = server.keySet(clock: clock)
        _ = await keys.key(for: issuer.keyID)
        clock.advance(by: 60)

        for attempt in 0 ..< 20 {
            #expect(await keys.key(for: "forged-\(attempt)") == nil)
        }
        #expect(server.fetches == 2)

        clock.advance(by: 59)
        #expect(await keys.key(for: "forged-again") == nil)
        #expect(server.fetches == 2)

        clock.advance(by: 1)
        #expect(await keys.key(for: "forged-once-more") == nil)
        #expect(server.fetches == 3)
    }

    @Test func aKeyPublishedLaterIsPickedUpAfterTheMinute() async {
        let old = TestTokenIssuer()
        let rotated = TestTokenIssuer()
        let server = FakeJWKS(.keys(old.jwks))
        let keys = server.keySet(clock: clock)
        #expect(await keys.key(for: old.keyID) != nil)

        // The first fetch was a moment ago, so the new key waits out the rest of the minute, which
        // is the price of a burst of forged kids not reaching runbloom.app.
        server.answer(.keys(TestTokenIssuer.jwks([old, rotated])))
        #expect(await keys.key(for: rotated.keyID) == nil)
        #expect(server.fetches == 1)

        clock.advance(by: 60)
        #expect(await keys.key(for: rotated.keyID) != nil)
        #expect(await keys.key(for: old.keyID) != nil)
    }

    @Test func aNotFoundKeySetRefusesEverythingAndIsNotRefetchedWithinTheMinute() async {
        let issuer = TestTokenIssuer()
        let server = FakeJWKS(.notFound)
        let keys = server.keySet(clock: clock)

        #expect(await keys.key(for: issuer.keyID) == nil)
        #expect(await keys.key(for: issuer.keyID) == nil)
        #expect(server.fetches == 1)

        server.answer(.keys(issuer.jwks))
        clock.advance(by: 60)
        #expect(await keys.key(for: issuer.keyID) != nil)
        #expect(server.fetches == 2)
    }

    @Test func aNotFoundAfterKeysEmptiesTheSet() async {
        let issuer = TestTokenIssuer()
        let server = FakeJWKS(.keys(issuer.jwks))
        let keys = server.keySet(clock: clock)
        #expect(await keys.key(for: issuer.keyID) != nil)

        server.answer(.notFound)
        clock.advance(by: 60)
        #expect(await keys.key(for: "rotated") == nil)
        #expect(await keys.key(for: issuer.keyID) == nil)
    }

    @Test func aNetworkFailureKeepsTheKeysThereWere() async {
        let issuer = TestTokenIssuer()
        let server = FakeJWKS(.keys(issuer.jwks))
        let keys = server.keySet(clock: clock)
        #expect(await keys.key(for: issuer.keyID) != nil)

        server.fail()
        clock.advance(by: 60)
        #expect(await keys.key(for: "rotated") == nil)
        #expect(server.fetches == 2)
        #expect(await keys.key(for: issuer.keyID) != nil)
    }

    @Test func anUnreadableBodyKeepsTheKeysThereWere() async {
        let issuer = TestTokenIssuer()
        let server = FakeJWKS(.keys(issuer.jwks))
        let keys = server.keySet(clock: clock)
        #expect(await keys.key(for: issuer.keyID) != nil)

        server.answer(.keys(Data("<html>".utf8)))
        clock.advance(by: 60)
        #expect(await keys.key(for: "rotated") == nil)
        #expect(await keys.key(for: issuer.keyID) != nil)
    }

    @Test func concurrentMissesShareOneFetch() async {
        let issuer = TestTokenIssuer()
        let server = FakeJWKS(.keys(issuer.jwks))
        let keys = server.keySet(clock: clock)

        let found = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 10 {
                group.addTask { await keys.key(for: issuer.keyID) != nil }
            }
            return await group.reduce(into: 0) { count, hit in count += hit ? 1 : 0 }
        }
        #expect(found == 10)
        #expect(server.fetches == 1)
    }

    @Test func keysThisServerCannotUseAreSkipped() async throws {
        let issuer = TestTokenIssuer()
        let short = Base64URL.encode(Data(repeating: 7, count: 31))
        let document: [String: Any] = [
            "keys": [
                ["kty": "RSA", "kid": "rsa", "n": "abc", "e": "AQAB"],
                ["kty": "OKP", "crv": "X25519", "kid": "x25519", "x": issuer.jwk["x"] ?? ""],
                ["kty": "OKP", "crv": "Ed25519", "kid": "short", "x": short],
                ["kty": "OKP", "crv": "Ed25519", "kid": "padded", "x": (issuer.jwk["x"] ?? "") + "="],
                ["kty": "OKP", "crv": "Ed25519", "kid": "encryption", "use": "enc", "x": issuer.jwk["x"] ?? ""],
                issuer.jwk,
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: document)
        let parsed = try #require(KeySet.parse(body))
        #expect(Set(parsed.keys) == [issuer.keyID])
    }

    @Test func aKeyWithoutAKeyIDIsFoundByItsThumbprint() async throws {
        let issuer = TestTokenIssuer(keyID: "ignored")
        var entry = issuer.jwk
        entry["kid"] = nil
        let body = try JSONSerialization.data(withJSONObject: ["keys": [entry]])
        let thumbprint = JWKThumbprint.ed25519(x: entry["x"] ?? "")
        #expect(KeySet.parse(body)?[thumbprint] != nil)
    }

    @Test func theThumbprintMatchesRFC8037() {
        // The worked example in RFC 8037, appendix A.3.
        let x = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
        #expect(JWKThumbprint.ed25519(x: x) == "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k")
    }
}

/// runbloom.app's JWKS endpoint, answering whatever the test last told it to and counting requests.
private final class FakeJWKS: Sendable {
    private enum Answer {
        case fetch(KeySetFetch)
        case failure
    }

    private struct Unreachable: Error {}

    private let state: Mutex<(answer: Answer, fetches: Int)>

    init(_ answer: KeySetFetch) {
        state = Mutex((.fetch(answer), 0))
    }

    var fetches: Int { state.withLock { $0.fetches } }

    func answer(_ answer: KeySetFetch) {
        state.withLock { $0.answer = .fetch(answer) }
    }

    func fail() {
        state.withLock { $0.answer = .failure }
    }

    func keySet(clock: TestClock) -> KeySet {
        KeySet(fetch: { try self.request() }, now: clock.reading)
    }

    private func request() throws -> KeySetFetch {
        let answer = state.withLock { current in
            current.fetches += 1
            return current.answer
        }
        switch answer {
        case .fetch(let fetch): return fetch
        case .failure: throw Unreachable()
        }
    }
}

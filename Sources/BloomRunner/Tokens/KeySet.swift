import AsyncHTTPClient
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What one request for runbloom.app's JWKS came back with.
public enum KeySetFetch: Sendable {
    /// The body of a 2xx answer.
    case keys(Data)
    /// runbloom.app answered 404, which is what it does while Cloud workspaces are switched off.
    case notFound
}

/// A non-2xx answer other than 404 from the key set's address.
public struct KeySetFetchFailure: Error, Sendable, Hashable {
    public var status: UInt
}

/// runbloom.app's signing keys, fetched from its JWKS and cached.
///
/// Refetched only when a token names a `kid` the cache does not hold, which is what a key rotation
/// looks like from here, and then at most once per `minimumRefetchInterval`. The limit is the point:
/// a `kid` is chosen by whoever wrote the token, so without it a stream of forged tokens with
/// random `kid`s would become a stream of requests to runbloom.app. Every attempt counts toward
/// it, a 404 or a failure as much as a success.
///
/// A known key is also checked again once `maximumAge` has passed since the last successful fetch,
/// so a key runbloom.app withdrew stops being honoured within the hour on a machine that stays up
/// for days, rather than at its next restart. runbloom.app keeps a retired key published for a day
/// after it stops signing, so this never refuses a token that was fine.
///
/// A 404 empties the set, because it means runbloom.app has switched the feature off and nothing it
/// signed should be honoured. A network failure or a body that does not parse keeps the set there
/// was, because a blip at runbloom.app should not lock every person out of a running workspace.
public actor KeySet {
    private let fetch: @Sendable () async throws -> KeySetFetch
    private let now: @Sendable () -> Date
    private let minimumRefetchInterval: TimeInterval
    private let maximumAge: TimeInterval

    private var keys: [String: Curve25519.Signing.PublicKey] = [:]
    private var lastAttempt: Date?
    private var lastLoaded: Date?
    /// Callers who miss the cache while a fetch is under way wait for that one rather than
    /// starting their own, or skipping it because the limit has just been used.
    private var inFlight: Task<Void, Never>?

    public init(
        fetch: @escaping @Sendable () async throws -> KeySetFetch,
        now: @escaping @Sendable () -> Date = Date.init,
        minimumRefetchInterval: Duration = .seconds(60),
        maximumAge: Duration = .seconds(3_600)
    ) {
        self.fetch = fetch
        self.now = now
        let parts = minimumRefetchInterval.components
        self.minimumRefetchInterval = TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
        self.maximumAge = TimeInterval(maximumAge.components.seconds)
    }

    public func key(for kid: String) async -> Curve25519.Signing.PublicKey? {
        if let loaded = lastLoaded, now().timeIntervalSince(loaded) >= maximumAge { await refreshIfAllowed() }
        if let key = keys[kid] { return key }
        await refreshIfAllowed()
        return keys[kid]
    }

    private func refreshIfAllowed() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let started = now()
        if let lastAttempt, started.timeIntervalSince(lastAttempt) < minimumRefetchInterval { return }
        lastAttempt = started
        let task = Task { await self.load() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func load() async {
        let outcome: KeySetFetch
        do {
            outcome = try await fetch()
        } catch {
            return
        }
        switch outcome {
        case .notFound:
            keys = [:]
            lastLoaded = now()
        case .keys(let body):
            if let parsed = Self.parse(body) {
                keys = parsed
                lastLoaded = now()
            }
        }
    }

    /// Nil when the body is not a JWKS at all. Keys this server cannot use are skipped rather than
    /// failing the set, so runbloom.app can publish another kind of key beside these one day.
    static func parse(_ body: Data) -> [String: Curve25519.Signing.PublicKey]? {
        guard let document = try? JSONDecoder().decode(Document.self, from: body) else { return nil }
        var parsed: [String: Curve25519.Signing.PublicKey] = [:]
        for entry in document.keys {
            guard entry.kty == "OKP", entry.crv == "Ed25519", let x = entry.x,
                  let raw = Base64URL.decode(x), raw.count == 32,
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
            else { continue }
            if let use = entry.use, use != "sig" { continue }
            if let alg = entry.alg, alg != "EdDSA" { continue }
            parsed[entry.keyName ?? JWKThumbprint.ed25519(x: x)] = key
        }
        return parsed
    }

    private struct Document: Decodable {
        var keys: [Entry]
    }

    /// Every member optional, so one odd key cannot make the whole document undecodable.
    private struct Entry: Decodable {
        var kty: String?
        var crv: String?
        var x: String?
        var keyName: String?
        var alg: String?
        var use: String?

        enum CodingKeys: String, CodingKey {
            case kty, crv, x, alg, use
            case keyName = "kid"
        }
    }
}

extension KeySet {
    /// The key set a machine uses: runbloom.app's JWKS at the address written into
    /// `/etc/bloom/workspace.json`, never one read from a token.
    public static func live(url: String, client: HTTPClient) -> KeySet {
        KeySet(fetch: {
            var request = HTTPClientRequest(url: url)
            request.headers.add(name: "Accept", value: "application/json")
            let response = try await client.execute(request, timeout: .seconds(5))
            if response.status.code == 404 { return .notFound }
            guard (200 ..< 300).contains(response.status.code) else {
                throw KeySetFetchFailure(status: response.status.code)
            }
            // A key set is a few hundred bytes. The cap is only there so a wrong address cannot
            // have this read a large file into memory.
            let body = try await response.body.collect(upTo: 1 << 20)
            return .keys(Data(body.readableBytesView))
        })
    }
}

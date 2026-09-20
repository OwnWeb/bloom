import BloomCore
import Foundation
import Synchronization
import Testing
@testable import BloomRunner

/// Item 8 of the review of 19 September 2026: a preview cookie lets its holder in for its hour and
/// not a second longer, and not at all once its person or share link has been revoked.
@Suite("Who a preview cookie lets in")
struct PreviewSessionsTests {
    final class Clock: Sendable {
        let current = Mutex(Date(timeIntervalSince1970: 1_789_638_000))
        var now: Date { current.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
    }

    private static func sessions(_ clock: Clock) throws -> (PreviewSessions, Revocations) {
        let store = try Store(path: SetupTestSupport.directory("preview-sessions") + "/bloom.sqlite")
        let revocations = Revocations(now: { clock.now })
        return (PreviewSessions(store: store, revocations: revocations, now: { clock.now }), revocations)
    }

    @Test("a cookie lets its subject in until it expires, and not after")
    func expiry() async throws {
        let clock = Clock()
        let (sessions, _) = try Self.sessions(clock)
        let cookie = await sessions.create(subject: "user-1", lifetime: PreviewRoutes.cookieLifetime)
        #expect(await sessions.subject(for: cookie) == "user-1")
        clock.advance(PreviewRoutes.cookieLifetime - 1)
        #expect(await sessions.subject(for: cookie) == "user-1")
        clock.advance(2)
        #expect(await sessions.subject(for: cookie) == nil)
        clock.advance(-10)
        #expect(await sessions.subject(for: cookie) == nil, "an expired cookie is forgotten, not merely refused")
    }

    @Test("a revoked person or share link loses the cookies handed out before, and not ones after")
    func revocation() async throws {
        let clock = Clock()
        let (sessions, revocations) = try Self.sessions(clock)
        let person = await sessions.create(subject: "user-1", lifetime: 3_600)
        let share = await sessions.create(subject: "share:01k5link", lifetime: 3_600)
        let other = await sessions.create(subject: "user-2", lifetime: 3_600)
        clock.advance(60)
        await revocations.revoke("user-1")
        await revocations.revoke("share:01k5link")
        #expect(await sessions.subject(for: person) == nil)
        #expect(await sessions.subject(for: share) == nil)
        #expect(await sessions.subject(for: other) == "user-2", "somebody else's cookie is untouched")
        // Past the clock skew a revocation allows for, a fresh entry is a fresh decision.
        clock.advance(TokenVerifier.clockSkew + 1)
        let again = await sessions.create(subject: "user-1", lifetime: 3_600)
        #expect(await sessions.subject(for: again) == "user-1")
    }

    @Test("an unknown or overlong cookie lets nobody in")
    func unknown() async throws {
        let (sessions, _) = try Self.sessions(Clock())
        #expect(await sessions.subject(for: "not-a-cookie") == nil)
        #expect(await sessions.subject(for: String(repeating: "a", count: 129)) == nil)
    }
}

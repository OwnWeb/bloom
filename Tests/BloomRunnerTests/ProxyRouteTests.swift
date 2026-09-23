import BloomCore
import Foundation
import Testing
@testable import BloomRunner

/// Who may forward a port out of a workspace, and which ports may never be forwarded.
///
/// **The splice itself is not tested here, it was measured.** A Sprite with PostgreSQL in it, this
/// route's design, a Mac client and `psql` returning rows, on 22 September 2026, before the route
/// was written. What a test can hold is the two decisions taken before a byte moves, and those are
/// the two that keep somebody out.
@Suite("Forwarding a port out of a workspace")
struct ProxyRouteTests {
    // A token is signed at the clock's reading rather than at the real time, so a token minted
    // here and the verifier reading this clock cannot fall either side of a moment. See `TestClock`.
    let issuer = TestTokenIssuer()
    let clock = TestClock()

    @Test("a session token with the terminal ability may forward")
    func allowsATerminalToken() async throws {
        let token = try await ProxyRoute.authorise(issuer.session(issuedAt: clock.now), verifier: issuer.verifier(clock: clock))
        #expect(token.abilities.contains("terminal"))
    }

    @Test("somebody who may only look at the workspace may not open its ports on their Mac")
    func refusesAViewOnlyToken() async {
        let viewer = issuer.session(abilities: ["view", "prompt"], issuedAt: clock.now)
        await #expect(throws: RemoteFailure.self) {
            _ = try await ProxyRoute.authorise(viewer, verifier: issuer.verifier(clock: clock))
        }
    }

    @Test("a preview token is not a forward")
    func refusesAPreviewToken() async {
        await #expect(throws: (any Error).self) {
            _ = try await ProxyRoute.authorise(issuer.preview(issuedAt: clock.now), verifier: issuer.verifier(clock: clock))
        }
    }

    @Test("an expired token does not forward, however right it was a minute ago")
    func refusesAnExpiredToken() async {
        let stale = issuer.session(issuedAt: clock.now.addingTimeInterval(-600), lifetime: 300)
        await #expect(throws: RemoteFailure.self) {
            _ = try await ProxyRoute.authorise(stale, verifier: issuer.verifier(clock: clock))
        }
    }

    @Test("Bloom's own ports are refused, and named in the refusal")
    func refusesReservedPorts() {
        let refusal = ProxyRoute.refusal(forwarding: 8081, reserved: [8080, 8081])
        #expect(refusal?.contains("8081") == true)
        #expect(ProxyRoute.refusal(forwarding: 8080, reserved: [8080, 8081]) != nil)
    }

    @Test("a port nothing holds is allowed")
    func allowsAnOrdinaryPort() {
        #expect(ProxyRoute.refusal(forwarding: 5432, reserved: [8080, 8081]) == nil)
    }

    @Test("a port outside the range is refused before anything is dialled")
    func refusesImpossiblePorts() {
        #expect(ProxyRoute.refusal(forwarding: 0, reserved: []) != nil)
        #expect(ProxyRoute.refusal(forwarding: 70_000, reserved: []) != nil)
        #expect(ProxyRoute.refusal(forwarding: -1, reserved: []) != nil)
    }

    @Test("the refusal codes are the ones a client acts on")
    func refusalCodes() {
        // A client retries 4502 when the service comes up, and never retries the other two. The
        // numbers are on the wire, so they are pinned here rather than left to be renumbered.
        #expect(ProxyRoute.Refusal.unauthenticated.rawValue == 4401)
        #expect(ProxyRoute.Refusal.portRefused.rawValue == 4403)
        #expect(ProxyRoute.Refusal.cannotReachPort.rawValue == 4502)
    }
}

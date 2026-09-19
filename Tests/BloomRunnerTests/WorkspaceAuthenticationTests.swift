import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing
@testable import BloomCore
@testable import BloomRunner

/// **Nobody gives an instruction to a workspace that is not theirs**, asked for by Freek in those
/// words, and held on the machine whatever runbloom.app gets right or wrong.
///
/// Every way a person's token can cause work here is tried with the four tokens that must not: one
/// runbloom.app minted for another workspace, signed by the same key, which is the realistic forgery,
/// since every machine trusts that key; one that has expired; a preview token, which only ever
/// grants looking at the app; and one whose abilities do not include what is being asked. Each is
/// refused at the door, before anything is queued. `TokenVerifierTests` covers the verifier's own
/// rules one by one; this is the same answer read at each route, so a route that forgot to ask
/// cannot pass.
extension WorkspaceHTTPServerTests {
    /// Signed by runbloom.app's own key, correct in every way but the workspace it names.
    static var otherWorkspace: [String: Any] { ["aud": "bloom-workspace:01k5a7d3v1x0m8n2q4r6s9t0zz"] }

    static func expired(_ issuer: TestTokenIssuer) -> String {
        issuer.session(issuedAt: Date().addingTimeInterval(-400), lifetime: 300)
    }

    @Test("a token for another workspace, an expired one and a preview token cannot command, watch or type")
    func foreignTokensAreRefusedEverywhere() async throws {
        let fixture = try await fixture()
        let issuer = fixture.issuer
        let refused = [
            ("another workspace", issuer.session(overrides: Self.otherWorkspace)),
            ("expired", Self.expired(issuer)),
            ("preview", issuer.preview()),
        ]
        let send = try Self.body(CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Delete the repository")))
        try await fixture.server.application(port: 0).test(.router) { client in
            for (label, token) in refused {
                try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(token), body: send) { response in
                    #expect(response.status == .unauthorized, "\(label) was let in to command")
                }
                try await client.execute(uri: "/_bloom/v1/events", method: .get, headers: Self.bearer(token)) { response in
                    #expect(response.status == .unauthorized, "\(label) was let in to watch")
                }
                try await client.execute(uri: "/_bloom/v1/streams/any/token", method: .post, headers: Self.bearer(token)) { response in
                    #expect(response.status == .unauthorized, "\(label) renewed a stream")
                }
                await #expect(throws: RemoteFailure.self, "\(label) was let in to a terminal") {
                    _ = try await TerminalRoute.authorise(token, verifier: fixture.verifier)
                }
            }
        }
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).isEmpty, "nothing was queued")
        #expect(try await fixture.store.messages(sessionID: fixture.session.id).isEmpty, "nothing was written")
        await fixture.runtime.shutdown()
    }

    @Test("a preview token for another workspace, or an expired one, does not open the preview")
    func foreignPreviewTokensAreRefused() async throws {
        let fixture = try await fixture()
        let issuer = fixture.issuer
        let refused = [
            issuer.preview(overrides: Self.otherWorkspace),
            issuer.preview(issuedAt: Date().addingTimeInterval(-120), lifetime: 60),
            // A session token is not a preview token either, however much it may do elsewhere.
            issuer.session(),
        ]
        try await fixture.server.application(port: 0).test(.router) { client in
            for token in refused {
                try await client.execute(uri: "/_bloom/preview/enter?token=\(token)", method: .get) { response in
                    #expect(response.status == .unauthorized)
                    #expect(response.headers[.setCookie] == nil, "no cookie for a token that was refused")
                }
            }
        }
        await fixture.runtime.shutdown()
    }

    /// Read access is not write access: a viewer is refused the send, a token without `view` cannot
    /// watch, and one without `terminal` gets no shell.
    @Test("a token without the ability being asked for is refused it, and only it")
    func abilitiesAreHeldAtEachDoor() async throws {
        let fixture = try await fixture()
        let issuer = fixture.issuer
        let viewer = issuer.session(abilities: ["view"])
        let send = try Self.body(CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Push to main")))
        try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(viewer), body: send) { response in
                let reply = try WireJSON.decode(CommandReply.self, from: Data(buffer: response.body))
                #expect(reply.error?.code == .missingAbility)
            }
            // The same viewer can still read, which is what tells a refusal from a broken route.
            try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(viewer),
                                     body: try Self.body(CommandRequest(.workspace))) { response in
                let reply = try WireJSON.decode(CommandReply.self, from: Data(buffer: response.body))
                #expect(reply.error == nil)
            }
            try await client.execute(uri: "/_bloom/v1/events", method: .get,
                                     headers: Self.bearer(issuer.session(abilities: ["prompt"]))) { response in
                #expect(response.status != .ok, "a token without view watched the workspace")
            }
        }
        await #expect(throws: RemoteFailure.self) {
            _ = try await TerminalRoute.authorise(viewer, verifier: fixture.verifier)
        }
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).isEmpty)
        await fixture.runtime.shutdown()
    }

    /// **Removed from the team while holding a live token.** runbloom.app's `revoke` control call is
    /// what makes it immediate: from then on every token issued before it is refused, on every door,
    /// though each one still has minutes to run. Without that call the token lasts until it expires,
    /// five minutes at most, and nothing renews it, because runbloom.app no longer issues them.
    @Test("a token issued before its subject was revoked is refused at once, though it has not expired")
    func aRevokedPersonIsRefusedBeforeTheirTokenExpires() async throws {
        let fixture = try await fixture()
        let token = fixture.issuer.session(issuedAt: Date().addingTimeInterval(-5))
        await fixture.verifier.revocations.revoke(TestTokenIssuer.defaultUserID)
        let send = try Self.body(CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "One more thing")))
        try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(token), body: send) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: "/_bloom/v1/events", method: .get, headers: Self.bearer(token)) { response in
                #expect(response.status == .unauthorized)
            }
        }
        await #expect(throws: RemoteFailure.self) {
            _ = try await TerminalRoute.authorise(token, verifier: fixture.verifier)
        }
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).isEmpty)
        await fixture.runtime.shutdown()
    }

    /// **A stream does not outlive its token**, which is what bounds a missed `revoke`: runbloom.app
    /// stops issuing tokens to a removed person, nothing renews their stream, and it closes. Asked
    /// by the control server's audit, because a `revoke` is retried for about 75 seconds and then
    /// abandoned.
    @Test("an event stream whose token has run out is closed with token_expired")
    func anEventStreamClosesAtExpiry() async throws {
        let streams = EventStreams()
        let (_, closing) = try await streams.open(for: Self.token(expiresAt: Date().addingTimeInterval(-1)))
        var reasons = closing.makeAsyncIterator()
        let reason = await reasons.next()
        #expect(reason?.code == .tokenExpired)
        #expect(await streams.count == 0)
    }

    /// M3 in the review of 19 September 2026: a viewer opening streams in a loop and never reading.
    @Test("a person holds at most so many streams, and somebody else is not held to theirs")
    func streamsAreCappedPerPerson() async throws {
        let streams = EventStreams()
        let token = Self.token(expiresAt: Date().addingTimeInterval(300))
        for _ in 0..<EventStreams.perPersonLimit { _ = try await streams.open(for: token) }
        await #expect(throws: RemoteFailure.self) { _ = try await streams.open(for: token) }
        _ = try await streams.open(for: Self.token(subject: "01k5a7c2b0z9y8x7w6v5t4s3zz", expiresAt: Date().addingTimeInterval(300)))
    }

    /// The other half of M3: frames nobody reads end the stream, rather than piling up in memory.
    @Test("a stream whose reader stops is ended once its buffer is full")
    func aSlowReaderIsLetGo() async throws {
        let (events, source) = AsyncStream.makeStream(of: WorkspaceEvent.self)
        let (closing, _) = AsyncStream.makeStream(of: WireError.self)
        let overflowed = Mutex(false)
        let merged = EventStreamRoute.merge(events: events, closing: closing, bufferLimit: 4) { overflowed.withLock { $0 = true } }
        for _ in 0..<50 { source.yield(.presence([])) }
        // Nothing reads until the stream has given up on its reader, which is the whole scenario.
        #expect(await SetupTestSupport.eventually { overflowed.withLock { $0 } })
        var received = 0
        for await _ in merged { received += 1 }
        #expect(received == 4, "the buffer, and then the end of the stream")
        source.finish()
    }

    /// L4: a socket is upgraded before its token is read, so the ones waiting are capped.
    @Test("only so many terminal sockets wait to authenticate, and a place comes back when one does")
    func unauthenticatedTerminalsAreCapped() async {
        let connections = TerminalConnections()
        for _ in 0..<TerminalConnections.unauthenticatedLimit {
            #expect(await connections.admitUnauthenticated())
        }
        #expect(await !connections.admitUnauthenticated())
        await connections.authenticated()
        #expect(await connections.admitUnauthenticated())
    }

    @Test("a terminal whose token has run out is closed")
    func aTerminalClosesAtExpiry() async throws {
        let closed = Mutex(false)
        try await TerminalRoute.closeAtExpiry(TerminalExpiry(expiresAt: Date().addingTimeInterval(-1))) {
            closed.withLock { $0 = true }
        }
        #expect(closed.withLock { $0 })
    }

    @Test("a stream is renewed only with the same person's token")
    func aStreamIsRenewedOnlyByItsOwnPerson() async throws {
        let streams = EventStreams()
        let (id, _) = try await streams.open(for: Self.token(expiresAt: Date().addingTimeInterval(300)))
        await #expect(throws: RemoteFailure.self) {
            try await streams.refresh(id, with: Self.token(subject: "01k5a7c2b0z9y8x7w6v5t4s3zz", expiresAt: Date().addingTimeInterval(600)))
        }
    }

    static func token(subject: String = TestTokenIssuer.defaultUserID, expiresAt: Date) -> WorkspaceToken {
        WorkspaceToken(use: .session, subject: subject, name: "Freek", email: nil, team: nil, abilities: ["view"],
                       issuedAt: expiresAt.addingTimeInterval(-300), expiresAt: expiresAt, jti: UUID().uuidString, signingKey: "k")
    }

    /// **A label the sender can leave out is not a label.** A token runbloom.app minted for an agent
    /// carries `act`, and the message is marked as an agent's even when the body says nothing.
    @Test("a message sent on a token minted for an agent is labelled as one, whatever the body says")
    func anActorTokenLabelsTheMessage() async throws {
        let fixture = try await fixture()
        let token = fixture.issuer.session(overrides: ["act": ["sub": "bloom-workspace:01k5origin", "turn": "01jturn"]])
        let send = try Self.body(CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "From another workspace")))
        let promptID = try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(token), body: send) { response -> String? in
                let reply = try WireJSON.decode(CommandReply.self, from: Data(buffer: response.body))
                guard case .queued(let id) = reply.result else { Issue.record("Not queued: \(String(buffer: response.body))"); return nil }
                return id
            }
        }
        // By the id the reply gave, not off the queue, which the drain may already have emptied.
        let id = try #require(promptID)
        let queued = try #require(try await fixture.store.delivery(id: DeliveryID(id)))
        #expect(queued.via != nil, "labelled from the signed claim, not from the body")
        await fixture.runtime.shutdown()
    }

    /// **H1 in the review of 19 September 2026.** A token runbloom.app minted for an agent, holding
    /// every ability a person can, reaches `workspace`, `new_chat` and `send` and nothing else: not
    /// a file, a download, a transcript, the composer's permission mode or an answer to a question.
    /// Every operation is tried, read from `Protocol/v1/vectors.json`, whose `schema.py --check`
    /// holds one example of every kind the Swift type has, so a new operation is tried here the
    /// day it gets its vector and is refused until `RemoteCaller.agentMayRun` names it.
    @Test("a token minted for an agent can find a chat, open one and send, and do nothing else")
    func anActorTokenCanOnlySend() async throws {
        let fixture = try await fixture()
        let token = fixture.issuer.session(overrides: ["act": ["sub": "bloom-workspace:01k5origin", "turn": "01jturn"]])
        let vectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Protocol/v1/vectors.json").standardizedFileURL
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: vectors)) as? [String: Any])
        let requests = try #require(file["requests"] as? [String: [String: Any]])
        let tried: [(name: String, kind: String, body: Data)] = try requests.sorted(by: { $0.key < $1.key }).map { name, request in
            let kind = try #require((request["operation"] as? [String: Any])?["kind"] as? String)
            return (name, kind, try JSONSerialization.data(withJSONObject: request))
        }
        try await fixture.server.application(port: 0).test(.router) { client in
            for (name, kind, data) in tried {
                let body = ByteBuffer(bytes: data)
                try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(token), body: body) { response in
                    let reply = try WireJSON.decode(CommandReply.self, from: Data(buffer: response.body))
                    if ["workspace", "new_chat", "send"].contains(kind) {
                        #expect(reply.error?.code != .missingAbility, "\(name) is what an agent's message needs")
                    } else {
                        #expect(reply.error?.code == .missingAbility, "\(name) was let through on an agent's token")
                    }
                }
            }
            try await client.execute(uri: "/_bloom/v1/events", method: .get, headers: Self.bearer(token)) { response in
                #expect(response.status == .forbidden, "an agent's token watched the workspace")
            }
            try await client.execute(uri: "/_bloom/v1/streams/any/token", method: .post, headers: Self.bearer(token)) { response in
                #expect(response.status == .forbidden, "an agent's token renewed a stream")
            }
        }
        // Forty-three kinds when this was written; fewer means the vectors were not read.
        #expect(Set(tried.map(\.kind)).count >= 43)
        await #expect(throws: RemoteFailure.self, "an agent's token opened a terminal") {
            _ = try await TerminalRoute.authorise(token, verifier: fixture.verifier)
        }
        await fixture.runtime.shutdown()
    }
}

import BloomCore
import Foundation
import Synchronization
import Testing
@testable import BloomRunner

/// The new machine's half of an opening prompt, against a runtime, with runbloom.app's two calls
/// standing in.
@Suite("Handing a new workspace its first message")
struct OpeningHandoffTests {
    static let opening = RemoteOpening(turnID: "01jopen", prompt: "Try the retry queue", controls: [:],
                                       promptedBy: .init(userID: "01k5a7c2b0z9y8x7w6v5t4s3rq", name: "Freek"))

    @Test("an opening image larger than the ordinary control answer limit can be fetched")
    func openingImageCanCrossTheControlConnection() async throws {
        let fake = try await FakeControlServer.start()
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared)
        let image = Data(repeating: 42, count: 1_100_000)
        fake.script("GET", "/opening", .json(200, ["opening": [
            "turn_id": "01jimage", "prompt": "Look at `.bloom/attachments/draft/shot.jpg`", "controls": [:],
            "prompted_by": ["user_id": "01k5a7c2b0z9y8x7w6v5t4s3rq", "name": "Freek"],
            "attachments": [["path": ".bloom/attachments/draft/shot.jpg", "name": "shot.jpg",
                             "data": image.base64EncodedString()]],
        ]]))

        let opening = try #require(try await client.opening())
        #expect(opening.attachments.first?.data == image)
        await fake.stop()
    }

    /// **A lost acknowledgement costs one more call, never a second chat.** The prompt is queued
    /// though runbloom.app was not told, and when the same opening comes back it is recognised by
    /// its turn and acknowledged again.
    @Test("an opening is queued though runbloom.app was not told, and a refetch is acknowledged rather than queued")
    func aLostAcknowledgement() async throws {
        let fixture = try await WorkspaceHTTPServerTests().fixture()
        let acknowledged = Mutex(0)
        let handoff = OpeningHandoff(
            fetch: { Self.opening },
            acknowledge: {
                acknowledged.withLock { $0 += 1 }
                throw RunbloomError.unreachable("runbloom.app answered 503.")
            },
            runtime: fixture.runtime
        )

        #expect(await handoff.run(), "queued even though runbloom.app never heard")
        let chats = try await fixture.store.sessions(workspaceID: fixture.runtime.workspaceID).count

        #expect(await handoff.run() == false, "the same opening again is not queued again")
        #expect(acknowledged.withLock { $0 } == 2, "but it is acknowledged again")
        #expect(try await fixture.store.sessions(workspaceID: fixture.runtime.workspaceID).count == chats, "no second chat")
        await fixture.runtime.shutdown()
    }

    /// test.55: the one `GET /opening` a boot made ran into `HTTPClientError.deadlineExceeded`, and
    /// nothing asked again before the next boot, so the opening turn stayed `queued` on
    /// runbloom.app for as long as the machine was up. runbloom.app answers the same opening to
    /// every read until it is acknowledged, so asking again is how it arrives.
    @Test("a fetch that times out or meets a 5xx is asked again until the opening arrives")
    func aFailedFetchIsAskedAgain() async throws {
        let fixture = try await WorkspaceHTTPServerTests().fixture()
        let fake = try await FakeControlServer.start()
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared)
        let timedOut = Mutex(false)
        fake.script("GET", "/opening", .init(status: 503, body: nil), .json(200, ["opening": [
            "turn_id": "01jopen", "prompt": "Try the retry queue", "controls": [:],
            "prompted_by": ["user_id": "01k5a7c2b0z9y8x7w6v5t4s3rq", "name": "Freek"], "expires_at": "2026-09-19T12:00:00Z",
        ]]))
        let handoff = OpeningHandoff(
            fetch: {
                // The first attempt fails the way test.55's did, before runbloom.app answers at all.
                if !timedOut.withLock({ $0 }) {
                    timedOut.withLock { $0 = true }
                    throw RunbloomError.unreachable("HTTPClientError.deadlineExceeded")
                }
                return try await client.opening()
            },
            acknowledge: { try await client.acknowledgeOpening() },
            runtime: fixture.runtime, retryDelay: .milliseconds(1)
        )

        #expect(await handoff.run(), "queued once runbloom.app answered")
        #expect(fake.requests("GET", "/opening").count == 2, "the 503, then the opening")
        #expect(fake.requests("DELETE", "/opening").count == 1)
        #expect(try await fixture.runtime.hasDeliveredOpening(turnID: "01jopen"))
        await fake.stop()
        await fixture.runtime.shutdown()
    }

    /// 404 is runbloom.app's answer, not a failure: a workspace a person made has no opening, and
    /// asking again would cost a call every boot for ever.
    @Test("no opening, or a refusal, is an answer and is not asked again")
    func anAnswerIsNotAskedAgain() async throws {
        let fixture = try await WorkspaceHTTPServerTests().fixture()
        let fake = try await FakeControlServer.start()
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared)
        let handoff = OpeningHandoff(
            fetch: { try await client.opening() }, acknowledge: { try await client.acknowledgeOpening() },
            runtime: fixture.runtime, retryDelay: .milliseconds(1)
        )

        fake.script("GET", "/opening", .refusal(status: 404, code: "not_found", message: "No opening."))
        #expect(await handoff.run() == false)
        fake.script("GET", "/opening", .refusal(status: 403, code: "forbidden", message: "Not yours."))
        #expect(await handoff.run() == false)

        #expect(fake.requests("GET", "/opening").count == 2, "one each")
        #expect(fake.requests("DELETE", "/opening").isEmpty)
        await fake.stop()
        await fixture.runtime.shutdown()
    }
}

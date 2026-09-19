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
        let chats = try await fixture.store.sessions(workspaceID: fixture.session.workspaceID).count

        #expect(await handoff.run() == false, "the same opening again is not queued again")
        #expect(acknowledged.withLock { $0 } == 2, "but it is acknowledged again")
        #expect(try await fixture.store.sessions(workspaceID: fixture.session.workspaceID).count == chats, "no second chat")
        await fixture.runtime.shutdown()
    }
}

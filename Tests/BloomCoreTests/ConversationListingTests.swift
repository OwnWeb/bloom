import Foundation
import Testing
@testable import BloomCore

@Suite("Project-free conversation listing")
struct ConversationListingTests {
    @Test func pinnedConversationsLeadWithoutMovingTheirPeers() {
        let first = Session(id: SessionID("first"), workspaceID: nil, sortOrder: 0)
        let second = Session(id: SessionID("second"), workspaceID: nil, sortOrder: 1)
        let third = Session(id: SessionID("third"), workspaceID: nil, sortOrder: 2)

        let ordered = ConversationListing.ordered(
            [first, second, third], pinned: [first.id, second.id]
        )
        #expect(ordered.map(\.id) == [second.id, first.id, third.id])
    }

    @Test func keysAreScopedToOneConversation() {
        let id = SessionID("chat")
        #expect(ConversationListing.pinnedKey(id) != ConversationListing.colourKey(id))
        #expect(ConversationListing.pinnedKey(id) != ConversationListing.pinnedKey(SessionID("other")))
    }

    @Test func dragStaysWithinPinnedAndUnpinnedRuns() throws {
        let pinned = Session(id: SessionID("pinned"), workspaceID: nil, sortOrder: 2)
        let first = Session(id: SessionID("first"), workspaceID: nil, sortOrder: 1)
        let second = Session(id: SessionID("second"), workspaceID: nil, sortOrder: 0)
        let rows = [pinned, first, second]
        let moved = try #require(ConversationListing.reordered(
            rows, pinned: [pinned.id], from: IndexSet(integer: 2), to: 1
        ))
        #expect(moved.map(\.id) == [pinned.id, second.id, first.id])
        #expect(ConversationListing.reordered(
            rows, pinned: [pinned.id], from: IndexSet(integer: 2), to: 0
        ) == nil)
    }

    @Test func waitingOutranksRunning() {
        #expect(ConversationListing.status(isRunning: true, isAwaitingPermission: true, isUnread: true)
                == .awaitingPermission)
        #expect(ConversationListing.status(isRunning: true, isAwaitingPermission: false, isUnread: true)
                == .running)
        #expect(ConversationListing.status(isRunning: false, isAwaitingPermission: false, isUnread: true)
                == .unread)
        #expect(ConversationListing.status(isRunning: false, isAwaitingPermission: false, isUnread: false)
                == .clean)
    }
}

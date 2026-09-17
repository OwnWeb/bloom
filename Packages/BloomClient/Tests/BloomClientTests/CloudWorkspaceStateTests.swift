@testable import BloomClient
import BloomProtocol
import Foundation
import Testing

/// The merging rules of the client chapter in docs/WORKSPACE-PROTOCOL.md.
@Suite struct CloudWorkspaceStateTests {
    @Test func aRowArrivingInAPageAndAsAnEventIsKeptOnce() {
        var state = CloudWorkspaceState()
        state.absorbPage(Records.page([Records.message(0), Records.message(1)]))
        state.apply(.message(Records.message(1)))
        state.apply(.message(Records.message(2)))
        #expect(state.chats["c1"]?.messages.map(\.seq) == [0, 1, 2])
    }

    @Test func anEventBeforeItsPageIsKeptAndThePageFillsInAroundIt() {
        var state = CloudWorkspaceState()
        state.apply(.message(Records.message(5)))
        let next = state.absorbPage(Records.page([Records.message(0), Records.message(1)], hasMore: true))
        #expect(next == 1)
        state.absorbPage(Records.page([Records.message(2), Records.message(3), Records.message(4), Records.message(5)]))
        #expect(state.chats["c1"]?.messages.map(\.seq) == [0, 1, 2, 3, 4, 5])
        #expect(state.chats["c1"]?.hasReadHistory == true)
    }

    @Test func theCursorIsTheLargestSeenAcrossChats() {
        var state = CloudWorkspaceState()
        state.absorb(Records.workspace(cursor: 100))
        state.apply(.message(Records.message(3, chat: "c2", cursor: 140)))
        state.apply(.message(Records.message(9, chat: "c1", cursor: 120)))
        #expect(state.cursor == 140)
        state.skip(cursor: 150)
        #expect(state.cursor == 150)
    }

    @Test func streamingTextIsReplacedAppendedAndDroppedByTheAssistantsRow() {
        var state = CloudWorkspaceState()
        state.apply(.stream(chatID: "c1", text: "Hel", snapshot: true))
        state.apply(.stream(chatID: "c1", text: "lo", snapshot: false))
        #expect(state.chats["c1"]?.streamingText == "Hello")
        state.apply(.stream(chatID: "c1", text: "Start again", snapshot: true))
        #expect(state.chats["c1"]?.streamingText == "Start again")
        state.apply(.message(Records.message(0, kind: "toolUse")))
        #expect(state.chats["c1"]?.streamingText == "Start again")
        state.apply(.message(Records.message(1, kind: "assistantText")))
        #expect(state.chats["c1"]?.streamingText == "")
    }

    @Test func aChatStateEventSettlesBusy() {
        var state = CloudWorkspaceState()
        state.absorbPage(Records.page([], chat: Records.chat(state: "running"), busy: true, streaming: "x"))
        #expect(state.chats["c1"]?.busy == true)
        state.apply(.chat(Records.chat(state: "idle")))
        #expect(state.chats["c1"]?.busy == false)
    }

    @Test func aChatNeverSeenBeforeAsksForItsHistory() {
        var state = CloudWorkspaceState()
        state.absorb(Records.workspace())
        #expect(state.apply(.chat(Records.chat("c1"))) == .none)
        #expect(state.apply(.chat(Records.chat("c2"))) == .newChat("c2"))
        #expect(state.topLevelChats.map(\.id) == ["c1", "c2"])
    }

    @Test func sleepingAndClosingAreReportedToTheCaller() {
        var state = CloudWorkspaceState()
        #expect(state.apply(.sleeping) == .sleeping)
        let expired = WireError(.tokenExpired, "Expired.")
        #expect(state.apply(.closing(expired)) == .closing(expired))
    }

    @Test func setupOutputIsCapped() {
        var state = CloudWorkspaceState()
        state.apply(.setupOutput(text: String(repeating: "x", count: CloudWorkspaceState.setupLogLimit)))
        state.apply(.setupOutput(text: "tail"))
        #expect(state.setupLog.utf8.count <= CloudWorkspaceState.setupLogLimit)
        #expect(state.setupLog.hasSuffix("tail"))
    }
}

@testable import BloomClient
import BloomProtocol
import Foundation
import Testing

/// The merging rules of the client chapter in docs/WORKSPACE-PROTOCOL.md.
@Suite struct CloudWorkspaceStateTests {
    /// **A machine that predates `composer_defaults` is still openable.** The field is required of
    /// a server, and a client that threw on a snapshot without it would not be missing a default,
    /// it would be refusing to open a workspace whose machine is merely older than the field. What
    /// is absent is absent, and the client falls back to its own choice.
    @Test func aSnapshotFromAMachineWithoutComposerDefaultsStillReads() throws {
        let json = """
        {"workspace": {"id": "01k5ws", "name": "Queue retries", "branch": "freek/queue-retries", "base_branch": "main", "setup": {"state": "succeeded"}}, "chats": [], "presence": [], "cursor": 77}
        """
        let snapshot = try WireJSON.decode(WorkspaceSnapshotRecord.self, from: Data(json.utf8))
        #expect(snapshot.composerDefaults == nil)
        #expect(snapshot.cursor == 77)

        var state = CloudWorkspaceState()
        state.absorb(snapshot)
        #expect(state.workspace?.name == "Queue retries")
        #expect(state.composerDefaults == nil, "nothing to fall back from is not something to invent")
    }

    /// And a snapshot that carries them puts them on the workspace, which is where a value with no
    /// chat id belongs: see `CloudWorkspaceState.composerDefaults`.
    @Test func aSnapshotWithComposerDefaultsKeepsThemOnTheWorkspace() {
        var state = CloudWorkspaceState()
        let controls = ComposerControlsRecord(agent: "codex", model: "gpt-5.5", effort: "medium",
                                              permissionMode: "auto", interactionMode: "build")
        state.absorb(Records.workspace(composerDefaults: controls))
        #expect(state.composerDefaults == controls)
        #expect(state.chats.values.allSatisfy { $0.chat?.model != "gpt-5.5" }, "not filed under a chat")
    }

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

    /// A machine that could not replay everything after the cursor leaves the client with a gap it
    /// cannot see. The cursor moves on, and every chat is marked unread so the histories are read
    /// again: this is what a runner restarting under an open window looks like from here.
    @Test func aSkippedCursorMakesEveryHistoryWorthReadingAgain() {
        var state = CloudWorkspaceState()
        state.absorb(Records.workspace(cursor: 100))
        _ = state.absorbPage(Records.page([Records.message(0), Records.message(1)]))
        #expect(state.chats["c1"]?.hasReadHistory == true)
        state.skip(cursor: 200)
        #expect(state.chats["c1"]?.hasReadHistory == false)
        #expect(state.cursor == 200)
        // And a page read again changes nothing that was already right: rows are keyed by seq.
        _ = state.absorbPage(Records.page([Records.message(0), Records.message(1)]))
        #expect(state.chats["c1"]?.messages.map(\.seq) == [0, 1])
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
        state.apply(.chat(Records.chat(state: "running")))
        #expect(state.chats["c1"]?.busy == true)
        state.apply(.chat(Records.chat(state: "idle")))
        #expect(state.chats["c1"]?.busy == false)
    }

    @Test func aPageReadBeforeTheTurnEndedPutsNothingStaleBack() {
        var state = CloudWorkspaceState()
        state.apply(.chat(Records.chat(state: "running")))
        state.apply(.stream(chatID: "c1", text: "Working", snapshot: true))
        state.apply(.message(Records.message(4, kind: "result")))
        state.apply(.chat(Records.chat(state: "idle")))
        // The page was served while the turn was still running.
        state.absorbPage(Records.page([Records.message(3)], chat: Records.chat(state: "running"), busy: true, streaming: "Work"))
        #expect(state.chats["c1"]?.busy == false)
        #expect(state.chats["c1"]?.streamingText == "")
        #expect(state.chats["c1"]?.chat?.state == "idle")
        #expect(state.chats["c1"]?.messages.map(\.seq) == [3, 4])
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

import BloomCore
import Foundation
import Testing

/// A Cloud workspace's strip, which follows the same rules as a local workspace's: see `CloudTabs`.
@Suite("Cloud tabs")
struct CloudTabsTests {
    private let one = SessionID("chat-1")
    private let two = SessionID("chat-2")

    @Test("a workspace with one chat is one tab and nothing else")
    func opensOnOneChat() {
        let tabs = CloudTabs()
        #expect(tabs.entries(chats: [one]) == [.chat(one)])
        #expect(tabs.selection(chats: [one]) == .chat(one))
        // Which is what keeps the strip off the screen, by the rule the local column keeps.
        #expect(!TabStripVisibility.isShown(tabCount: tabs.entries(chats: [one]).count))
    }

    @Test("opening a tool tab puts it after the chats and selects it")
    func opensATool() {
        var tabs = CloudTabs()
        let terminal = tabs.open(CloudTabs.Tool(kind: .terminal), chats: [one])
        #expect(tabs.entries(chats: [one]) == [.chat(one), terminal])
        #expect(tabs.selection(chats: [one]) == terminal)
        #expect(TabStripVisibility.isShown(tabCount: 2))
    }

    @Test("a workspace has one changes tab however often it is asked for, and many terminals")
    func uniqueKinds() {
        var tabs = CloudTabs()
        let first = tabs.open(CloudTabs.Tool(kind: .changes), chats: [])
        let again = tabs.open(CloudTabs.Tool(kind: .changes), chats: [])
        #expect(first == again)
        #expect(tabs.entries(chats: []).count == 1)
        tabs.open(CloudTabs.Tool(kind: .terminal), chats: [])
        tabs.open(CloudTabs.Tool(kind: .terminal), chats: [])
        #expect(tabs.entries(chats: []).count == 3)
    }

    @Test("closing the tab in front hands the selection to its neighbour")
    func closing() {
        var tabs = CloudTabs()
        let terminal = tabs.open(CloudTabs.Tool(kind: .terminal), chats: [one])
        tabs.select(.chat(two))
        let closedChat = tabs.close(.chat(two), chats: [one, two])
        // A chat is the machine's, so the caller is told to close it there.
        #expect(closedChat == two)
        // Its left neighbour takes the selection, which is the terminal opened before it.
        #expect(tabs.selection(chats: [one]) == terminal)
        let closedTool = tabs.close(terminal, chats: [one])
        #expect(closedTool == nil)
        #expect(tabs.entries(chats: [one]) == [.chat(one)])
    }

    @Test("the order a strip is dragged into is kept, and a new chat lands at the end of it")
    func reordering() {
        var tabs = CloudTabs()
        let terminal = tabs.open(CloudTabs.Tool(kind: .terminal), chats: [one])
        tabs.noteChats([one])
        tabs.reorder([terminal, .chat(one)], chats: [one])
        #expect(tabs.entries(chats: [one]) == [terminal, .chat(one)])
        tabs.noteChats([one, two])
        #expect(tabs.entries(chats: [one, two]) == [terminal, .chat(one), .chat(two)])
    }

    @Test("a tool tab keeps the name it was given, and a chat's name is the machine's")
    func renaming() {
        var tabs = CloudTabs()
        let terminal = tabs.open(CloudTabs.Tool(kind: .terminal), chats: [one])
        tabs.rename(terminal, to: "  Logs  ")
        #expect(tabs.tool(terminal)?.title == "Logs")
        tabs.rename(terminal, to: "   ")
        #expect(tabs.tool(terminal)?.title == PaneNaming.terminal)
        tabs.rename(.chat(one), to: "Ignored")
        #expect(tabs.title(of: .chat(one), chats: [.init(id: one, title: "Queue retries")]) == "Queue retries")
    }

    @Test("setup opens by itself while it is running or failed, once, and not over a chat")
    func setupTab() throws {
        var tabs = CloudTabs()
        // Lifted out of `#expect`, which rewrites its argument into a closure taking the value
        // immutably. See CLAUDE.md.
        let opened = tabs.revealSetupIfNeeded(state: "running", chats: [])
        #expect(opened)
        let setup = try #require(tabs.tool(kind: .setup)?.id)
        #expect(tabs.selection(chats: []) == .tool(setup))
        // Closed by a reader, it stays closed for that state.
        _ = tabs.close(.tool(setup), chats: [])
        let again = tabs.revealSetupIfNeeded(state: "running", chats: [])
        #expect(!again)
        // Failing is news, so it comes back, and a chat in front is not taken away.
        let failed = tabs.revealSetupIfNeeded(state: "failed", chats: [one])
        #expect(failed)
        #expect(tabs.selection(chats: [one]) == .chat(one))
    }

    @Test("a finished setup opens nothing")
    func setupDone() {
        var tabs = CloudTabs()
        let succeeded = tabs.revealSetupIfNeeded(state: "succeeded", chats: [one])
        let unknown = tabs.revealSetupIfNeeded(state: nil, chats: [])
        #expect(!succeeded)
        #expect(!unknown)
        #expect(tabs.tool(kind: .setup) == nil)
    }

    @Test("the strip survives being written down and read back")
    func codable() throws {
        var tabs = CloudTabs()
        let terminal = tabs.open(CloudTabs.Tool(kind: .terminal, name: "Logs", terminalName: "shell-01k5"), chats: [one, two])
        tabs.noteChats([one, two])
        tabs.reorder([.chat(two), terminal, .chat(one)], chats: [one, two])
        let read = try JSONDecoder().decode(CloudTabs.self, from: JSONEncoder().encode(tabs))
        #expect(read.entries(chats: [one, two]) == [.chat(two), terminal, .chat(one)])
        #expect(read.tool(terminal)?.terminalName == "shell-01k5")
        #expect(read.selection(chats: [one, two]) == terminal)
    }
}

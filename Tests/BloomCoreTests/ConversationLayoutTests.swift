import Foundation
import Testing
@testable import BloomCore

@Suite("Project-free conversation panes")
struct ConversationLayoutTests {
    @Test func chatRemainsReachableWhileToolsOpenAndClose() {
        var layout = ConversationLayout()
        let terminal = layout.open(.terminal)
        let browser = layout.open(.browser)

        #expect(layout.tabs.map(\.id) == [ConversationLayout.chatID, terminal.id, browser.id])
        #expect(layout.selectedTabID == browser.id)
        #expect(layout.closeTab(browser.id).map(\.id) == [browser.id])
        #expect(layout.selectedTabID == terminal.id)
        #expect(layout.closeTab(ConversationLayout.chatID).isEmpty)
        #expect(layout.tabs.first?.id == ConversationLayout.chatID)
    }

    @Test func splitAndCloseKeepTheConversationAndPersistTheShape() throws {
        var layout = ConversationLayout()
        let created = layout.split(
            tabID: ConversationLayout.chatID, paneID: ConversationLayout.chatID,
            axis: .horizontal, opening: .browser
        )
        let browser = try #require(created)
        layout.setURL("https://example.com", paneID: browser.id, in: ConversationLayout.chatID)
        layout.setRatio(0.35, at: [], in: ConversationLayout.chatID)

        let restored = try JSONDecoder().decode(ConversationLayout.self, from: JSONEncoder().encode(layout))
        #expect(restored.isValid)
        #expect(restored.tab(ConversationLayout.chatID)?.layout.paneCount == 2)
        #expect(restored.tab(ConversationLayout.chatID)?.pane(browser.id)?.url == "https://example.com")

        #expect(layout.closePane(tabID: ConversationLayout.chatID, paneID: ConversationLayout.chatID) == nil)
        #expect(layout.closePane(tabID: ConversationLayout.chatID, paneID: browser.id)?.id == browser.id)
        #expect(layout.tab(ConversationLayout.chatID)?.layout.paneCount == 1)
    }
}

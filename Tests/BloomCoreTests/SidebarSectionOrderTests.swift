import Testing
@testable import BloomCore

@Suite("Sidebar section dragging")
struct SidebarSectionOrderTests {
    @Test func movingFirstSectionDownSwapsAndPullingBackRestores() {
        let start = SidebarSectionOrder.workFirst

        #expect(start.dragging(.work, translation: 33) == .conversationsFirst)
        #expect(start.dragging(.work, translation: 20) == .workFirst)
        #expect(start.dragging(.work, translation: -40) == .workFirst)
    }

    @Test func movingSecondSectionUpSwapsInEitherOrder() {
        #expect(SidebarSectionOrder.workFirst.dragging(
            .conversations, translation: -33
        ) == .conversationsFirst)
        #expect(SidebarSectionOrder.conversationsFirst.dragging(
            .work, translation: -33
        ) == .workFirst)
    }

    @Test func movingConversationsDownFromFirstSwaps() {
        #expect(SidebarSectionOrder.conversationsFirst.dragging(
            .conversations, translation: 33
        ) == .workFirst)
    }
}

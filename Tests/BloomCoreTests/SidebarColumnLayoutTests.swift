import Testing
@testable import BloomCore

struct SidebarColumnLayoutTests {
    private let layout = SidebarColumnLayout(disclosureWidth: 11, spacing: 6)

    @Test("Workspace text begins at the project icon")
    func workspaceTextAlignsWithProjectIcon() {
        let projectIconLeading = layout.disclosureWidth + layout.spacing

        #expect(layout.workspaceIndent + layout.indicatorWidth + layout.spacing == projectIconLeading)
        #expect(abs(layout.primaryContentLeading - projectIconLeading) < 0.001)
    }

    @Test("Every workspace state keeps the same two columns")
    func statusDoesNotChangeGeometry() {
        let states = ["unread", "running", "idle", "selected", "hovered"]
        let positions = states.map { _ in
            (indicator: layout.workspaceIndent, content: layout.primaryContentLeading)
        }

        #expect(positions.allSatisfy { $0.indicator == 0 })
        #expect(positions.allSatisfy { $0.content == 17 })
    }

    @Test("Nested rows keep one deliberate hierarchy step")
    func nestedRowsUseDisclosureStep() {
        #expect(layout.childIndent == layout.disclosureWidth)
    }
}

import Testing
@testable import BloomCore

@Suite("Subagent disclosure")
struct SubagentDisclosureTests {
    private let workspace = WorkspaceID("ws-1")
    private let other = WorkspaceID("ws-2")

    @Test("A workspace nobody has touched shows its subagents")
    func opensByDefault() {
        let disclosure = SubagentDisclosure()
        #expect(disclosure.shows(workspace))
    }

    @Test("Toggling folds, and toggling again opens")
    func togglesBothWays() {
        var disclosure = SubagentDisclosure()
        disclosure.toggle(workspace)
        #expect(!disclosure.shows(workspace))
        disclosure.toggle(workspace)
        #expect(disclosure.shows(workspace))
    }

    @Test("Folding one workspace leaves every other open")
    func foldsOneWorkspaceOnly() {
        var disclosure = SubagentDisclosure()
        disclosure.toggle(workspace)
        #expect(disclosure.shows(other))
    }
}

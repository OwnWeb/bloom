import Foundation
import Testing
@testable import BloomCore

@Suite("Window pane preferences")
struct WindowPanePreferencesTests {
    @Test("The sidebar choice has a stable window key")
    func sidebarKey() {
        #expect(WindowPanePreferences.sidebarVisibleKey == "sidebar.isVisible")
    }

    @Test("Inspector choices survive a new defaults reader and stay separate by chat")
    func inspectorChoices() throws {
        let name = "bloom.window-panes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let workspace = SidebarSelection.workspace(WorkspaceID("workspace"))
        let first = SessionID("first")
        let second = SessionID("second")
        #expect(WindowPanePreferences.inspectorVisible(for: workspace, sessionID: first, in: defaults))

        WindowPanePreferences.setInspectorVisible(false, for: workspace, sessionID: first, in: defaults)

        let reopened = try #require(UserDefaults(suiteName: name))
        #expect(!WindowPanePreferences.inspectorVisible(for: workspace, sessionID: first, in: reopened))
        #expect(WindowPanePreferences.inspectorVisible(for: workspace, sessionID: second, in: reopened))
        #expect(!WindowPanePreferences.inspectorVisible(for: workspace, in: reopened))
        #expect(WindowPanePreferences.inspectorVisible(
            for: .workspace(WorkspaceID("another")), in: reopened
        ))
    }

    @Test("A child conversation keeps its parent workspace inspector choice")
    func childSelection() throws {
        let name = "bloom.window-panes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let workspaceID = WorkspaceID("parent")

        WindowPanePreferences.setInspectorVisible(false, for: .workspace(workspaceID), in: defaults)

        #expect(!WindowPanePreferences.inspectorVisible(
            for: .subagent(workspaceID, SubagentID("child")), in: defaults
        ))
        #expect(WindowPanePreferences.inspectorVisible(for: .home, in: defaults))
    }
}

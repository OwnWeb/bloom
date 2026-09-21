import Foundation
import BloomCore

/// Command-L belongs to the visible browser when the selected tab contains one, and keeps its
/// existing Add to Chat meaning everywhere else.
extension AppModel {
    var browserLocationTarget: String? {
        guard !isAskInFront, let workspace = selectedModel else { return nil }
        let workspaceTabs = WorkspaceTabsStore.shared
        guard let selected = workspaceTabs.selectedTab(in: workspace) else { return nil }
        let layout = workspaceTabs.layout(of: selected)
        let tools = CenterTabStore.shared.tabs(for: workspace.surfaceID)
        guard let pane = BrowserLocationTarget.resolve(
            focused: layout.focus,
            visible: layout.panes,
            isBrowser: { pane in
                guard case .tool(let id) = workspaceTabs.content(of: pane, in: selected) else {
                    return false
                }
                return tools.first(where: { $0.id == id })?.kind == .browser
            }
        ) else { return nil }
        if case .tool(let id) = workspaceTabs.content(of: pane, in: selected) {
            return id
        }
        return nil
    }

    /// True when a browser on screen accepted the command.
    func focusBrowserLocation() -> Bool {
        guard let target = browserLocationTarget else { return false }
        NotificationCenter.default.post(name: .bloomFocusBrowserLocation, object: target)
        return true
    }
}

extension Notification.Name {
    static let bloomFocusBrowserLocation = Notification.Name("bloom.focusBrowserLocation")
}

import Foundation

/// The sidebar belongs to the window; the inspector choice belongs to the conversation being read.
public enum WindowPanePreferences {
    public static let sidebarVisibleKey = "sidebar.isVisible"

    public static func inspectorVisible(
        for selection: SidebarSelection,
        sessionID: SessionID? = nil,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = inspectorKey(for: selection, sessionID: sessionID) else { return true }
        return defaults.object(forKey: key) as? Bool ?? true
    }

    public static func setInspectorVisible(
        _ visible: Bool,
        for selection: SidebarSelection,
        sessionID: SessionID? = nil,
        in defaults: UserDefaults = .standard
    ) {
        guard let key = inspectorKey(for: selection, sessionID: sessionID) else { return }
        defaults.set(visible, forKey: key)
        // Keep the workspace's last choice available while its active chat is loading.
        if sessionID != nil, let workspaceID = selection.workspaceID {
            defaults.set(visible, forKey: "inspector.visible.workspace.\(workspaceID.rawValue)")
        }
    }

    private static func inspectorKey(
        for selection: SidebarSelection,
        sessionID: SessionID?
    ) -> String? {
        if let workspaceID = selection.workspaceID {
            if let sessionID { return "inspector.visible.session.\(sessionID.rawValue)" }
            return "inspector.visible.workspace.\(workspaceID.rawValue)"
        }
        return nil
    }
}

import Observation
import BloomCore

/// Whether the Ask Bloom panel is in front of the window.
///
/// Shared rather than held by a view, for the reason `SearchPanelModel` is: the panel is drawn by
/// a hosting view over the window's frame view, and that host's hit test has to ask whether there
/// is anything up without being a SwiftUI view that could read an environment.
///
/// **The panel never opens over the full pane.** `SidebarSelection.ask` still draws the same
/// conversations in the centre column, and the panel over it would be two views of one transcript
/// on screen at once, each with its own scroll position and its own composer. So asking for the
/// panel while the full pane is showing is a request already met.
@MainActor
@Observable
final class AskPanelModel {
    static let shared = AskPanelModel()

    private(set) var isOpen = false

    private init() {}

    func open(app: AppModel) {
        guard app.selection != .ask else { return }
        SearchPanelModel.shared.close(app: app)
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
    }

    func toggle(app: AppModel) {
        if isOpen { close() } else { open(app: app) }
    }

    /// The panel's own expand button: the same conversations, given the whole centre column.
    func expand(app: AppModel) {
        close()
        app.selection = .ask
    }
}

extension AppModel {
    /// Whether the tab commands (New Tab, Close Tab, the tab cycle and Go to Tab) are about Ask
    /// Bloom's conversations rather than the selected workspace's tabs: the full pane is showing
    /// them, or the panel is in front of the window. With the panel up, Command-W closing a tab of
    /// the workspace hidden behind it would be closing something nobody is looking at.
    var isAskInFront: Bool { selection == .ask || AskPanelModel.shared.isOpen }
}

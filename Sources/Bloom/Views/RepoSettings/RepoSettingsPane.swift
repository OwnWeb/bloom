import Foundation

/// Which part of a project's settings is showing.
///
/// A type of its own rather than an enum nested inside the view, because things outside that view
/// answer to it: the sidebar that draws the choice, and a capture run that names the pane it wants
/// photographed.
///
/// Named `Pane` rather than `Tab` because `Tab` is SwiftUI's own type, and because these are not
/// tabs: they are rows in a sidebar, the way the app's own Settings window lists its panes.
enum RepoSettingsPane: String, CaseIterable, Hashable, Identifiable {
    case project
    case workspaces
    case scripts
    case instructions

    var id: String { rawValue }

    /// The word in the sidebar row.
    var title: String {
        switch self {
        case .project: "Project"
        case .workspaces: "Workspaces"
        case .scripts: "Scripts"
        case .instructions: "Instructions"
        }
    }

    /// The symbol beside that word.
    var systemImage: String {
        switch self {
        case .project: "folder"
        case .workspaces: "square.stack.3d.up"
        case .scripts: "terminal"
        case .instructions: "text.book.closed"
        }
    }

    /// Which pane a window opens on, from `BLOOM_PANE=workspaces|scripts|instructions`.
    ///
    /// A capture run can open this window through `--repo-settings` and cannot press anything in
    /// it, so without this the other two panes go in unverified. Nil for anything else, including
    /// nothing at all, and the window falls back to Project.
    static var requested: RepoSettingsPane? {
        guard let named = ProcessInfo.processInfo.environment["BLOOM_PANE"] else { return nil }
        return RepoSettingsPane(rawValue: named)
    }
}

import SwiftUI
import BloomCore

/// What the sidebar's two `+` buttons open: the toolbar's and the status bar's.
///
/// One view, because the two menus were already kept word for word the same by comments pointing
/// at each other, and a section of recent projects added to one and forgotten in the other is the
/// drift those comments existed to prevent.
///
/// The generic items stay first, so the position somebody aims at for "New workspace…" did not
/// move when the recent projects arrived. A recent project opens the same create window with that
/// project already chosen, through the path every other per project entry point uses. `recent` is
/// loaded by `SidebarView`, because the archived half of the answer is a store read and a menu's
/// content cannot wait for one.
struct NewMenuItems: View {
    var recent: [Repo]
    var onNewWorkspace: () -> Void
    var onStartProject: () -> Void
    var onCreateWorkspace: (Repo) -> Void

    var body: some View {
        Button("New workspace…", action: onNewWorkspace)
        Button("New project…", action: onStartProject)

        if !recent.isEmpty {
            Divider()
            Section("New workspace in") {
                ForEach(recent) { repo in
                    Button { onCreateWorkspace(repo) } label: {
                        // An `Image`, never `RepoIcon` itself: a SwiftUI view in a menu item's
                        // image slot blanks the title too. See `RepoIconImage`.
                        if let icon = RepoIconImage.of(repo) {
                            Label { Text(repo.name) } icon: { Image(nsImage: icon) }
                        } else {
                            Text(repo.name)
                        }
                    }
                }
            }
        }
    }
}

/// What `SidebarView` reloads the recent projects on. Ids rather than counts, because a workspace
/// archived and another started in one reload leaves the count where it was.
struct NewMenuRecentKey: Hashable {
    var workspaces: [WorkspaceID]
    var archivedRevision: Int
    var visibleProjects: [RepoID]

    @MainActor
    init(app: AppModel) {
        workspaces = app.workspaces.map(\.id)
        archivedRevision = app.archivedRevision
        visibleProjects = app.repos.filter { !$0.hidden }.map(\.id)
    }
}

import SwiftUI
import BloomCore

/// A searchable route to every project, including those without workspaces. A cascading native
/// menu made moving from the project list to an item unreliable when the list was this long.
struct SidebarProjectsBrowser: View {
    var repos: [Repo]
    var onSelect: (Repo) -> Void
    var onCreateWorkspace: (Repo) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var matches: [Repo] {
        guard !query.isEmpty else { return repos }
        return repos.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: Metrics.spacing) {
            TextField("Find project", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matches) { repo in
                        HStack(spacing: Metrics.spacingSmall) {
                            Button {
                                onSelect(repo)
                            } label: {
                                HStack(spacing: Metrics.spacingSmall) {
                                    RepoIcon(repo: repo)
                                    Text(repo.name)
                                        .lineLimit(1)
                                    if repo.hidden {
                                        Text("Hidden")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show \(repo.name) in the sidebar")

                            Menu {
                                Button("New workspace") { onCreateWorkspace(repo) }
                                Button("Project settings…") {
                                    openWindow(id: RepoSettingsWindow.id, value: repo.id)
                                }
                                Button(repo.hidden ? "Unhide project" : "Hide project") {
                                    Task { await app.toggleHidden(repo) }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
                            }
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel("Actions for \(repo.name)")
                        }
                        .frame(height: Metrics.rowHeight)
                    }
                }
            }
            .frame(height: 360)
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .padding(Metrics.spacing)
        .frame(width: 330)
        .onAppear { searchFocused = true }
    }
}

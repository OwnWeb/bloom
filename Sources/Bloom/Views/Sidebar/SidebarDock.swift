import SwiftUI
import BloomCore

/// Home and New at the leading end of the sidebar's status bar.
/// The former Ask Bloom button is gone. Project-free conversations have their own rows below
/// Projects, so a separate panel entry point would give the same chats two homes.
struct SidebarDock: View {
    @Environment(AppModel.self) private var app

    var onNewWorkspace: () -> Void
    var onStartProject: () -> Void
    var onCreateWorkspace: (Repo) -> Void
    var recentProjects: [Repo]

    @State private var hovered: Item?

    private enum Item { case home, new }

    var body: some View {
        HStack(spacing: Metrics.spacingTight) {
            Button { goHome() } label: {
                label("Home", systemImage: "house", item: .home, isActive: app.selection == .home)
            }
            .buttonStyle(.plain)
            .help("Home")

            Menu {
                NewMenuItems(
                    recent: recentProjects,
                    onNewWorkspace: onNewWorkspace,
                    onStartProject: onStartProject,
                    onCreateWorkspace: onCreateWorkspace
                )
            } label: {
                label("New", systemImage: "plus", item: .new, isActive: false)
            }
            // `.button` with `.plain` rather than `.borderlessButton`, for the reason measured on
            // the workspace row's own menu: the borderless style inks its label itself and ignores
            // the colour it is handed.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New workspace or project")

        }
    }

    private func goHome() {
        app.selection = .home
    }

    private func label(_ title: String, systemImage: String, item: Item, isActive: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(Typo.label)
            .foregroundStyle(isActive ? Palette.accent : Palette.textSecondary)
            .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
            .contentShape(Rectangle())
            .background(
                hovered == item ? Palette.hover : .clear,
                in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
            )
            .onHoverChange { hovered = $0 ? item : (hovered == item ? nil : hovered) }
    }
}

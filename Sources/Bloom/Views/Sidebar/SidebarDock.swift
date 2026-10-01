import SwiftUI
import BloomCore

/// The archive shortcut beside filter and help at the trailing end of the sidebar's status bar.
/// The toolbar and section headers already offer creation, so the footer only navigates.
struct SidebarDock: View {
    @Environment(AppModel.self) private var app

    @State private var isHovered = false

    var body: some View {
        Button { showArchive() } label: {
            Label("Archive", systemImage: "archivebox")
                .labelStyle(.iconOnly)
                .font(Typo.label)
                .foregroundStyle(isShowingArchive ? Palette.accent : Palette.textSecondary)
                .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
                .contentShape(Rectangle())
                .background(
                    isHovered ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                )
        }
        .buttonStyle(.plain)
        .onHoverChange { isHovered = $0 }
        .help("Archived workspaces and conversations")
    }

    private var isShowingArchive: Bool {
        app.selection == .home && app.homeFilter.scope == .archived
    }

    private func showArchive() {
        app.homeFilter.scope = .archived
        app.selection = .home
    }
}

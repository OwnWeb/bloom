import SwiftUI
import BloomCore

/// New tools in a project-free conversation use the same tab strip as project tools.
struct ConversationNewTabMenu: View {
    let state: ConversationPaneState

    var body: some View {
        Menu {
            Button(PaneKind.terminal.title, systemImage: PaneKind.terminal.symbol) {
                state.open(.terminal)
            }
            Button(PaneKind.browser.title, systemImage: PaneKind.browser.symbol) {
                state.open(.browser)
            }
        } label: {
            Label("New Tab", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("New Tab")
        .help("New tab in this conversation")
    }
}

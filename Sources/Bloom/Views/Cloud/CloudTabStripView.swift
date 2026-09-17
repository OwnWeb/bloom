import BloomCore
import SwiftUI

/// A Cloud workspace's tab strip, drawn with the tab chrome every strip in Bloom wears.
///
/// **An interim view, and it says so.** The tabs, their order, renaming and closing are already the
/// local column's rules (`CloudTabs` asks `TabSet`, `StripOrder` and `TabClosure`), and the chrome
/// is `TabItemView`, so what a reader sees and does here is the local strip. What is not shared yet
/// is the strip view itself, with its drag between panes and its splits: that arrives when
/// `CenterColumnView` takes a workspace through a protocol rather than as a `WorkspaceModel`. See
/// the plan in docs/REMOTE-WORKSPACES.md.
struct CloudTabStripView: View {
    var session: CloudWorkspaceSession
    @Binding var renamingID: String?
    @Namespace private var selection

    var body: some View {
        let entries = session.entries
        let selected = session.selectedTab
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element) { index, content in
                    TabItemView(
                        title: session.title(of: content),
                        icon: .symbol(icon(for: content)),
                        isActive: content == selected,
                        isRunning: isRunning(content),
                        isRenaming: renamingID == content.id,
                        editableTitle: session.title(of: content),
                        canClose: entries.count > 1 || !content.isChat,
                        closeTitle: content.isChat ? "Close chat" : "Close tab",
                        onSelect: { session.select(content) },
                        onStartRename: { renamingID = content.id },
                        onCommitRename: { name in
                            renamingID = nil
                            session.rename(content, to: name)
                        },
                        onCancelRename: { renamingID = nil },
                        onClose: { session.close(content) },
                        onMoveLeft: index > 0 ? { @MainActor in move(content, by: -1, in: entries) } : nil,
                        onMoveRight: index < entries.count - 1 ? { @MainActor in move(content, by: 1, in: entries) } : nil,
                        namespace: selection
                    )
                }
            }
            .padding(.horizontal, Metrics.spacingWide)
        }
        .frame(height: Metrics.barHeight)
        .background(Palette.windowBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func icon(for content: PaneContent) -> String {
        switch content {
        case .chat: PaneGlyph.chat
        case .tool(let id):
            switch session.tabs.tools.first(where: { $0.id == id })?.kind {
            case .terminal: PaneGlyph.terminal
            case .changes: "plusminus"
            case .setup: "hammer"
            case .notes, .none: "note.text"
            }
        }
    }

    private func isRunning(_ content: PaneContent) -> Bool {
        guard case .chat(let id) = content else { return false }
        return session.state.chats[id.rawValue]?.isRunning == true
    }

    private func move(_ content: PaneContent, by offset: Int, in entries: [PaneContent]) {
        guard let index = entries.firstIndex(of: content) else { return }
        var drawn = entries
        drawn.remove(at: index)
        drawn.insert(content, at: max(0, min(drawn.count, index + offset)))
        session.reorder(drawn)
    }
}

/// What the `+` offers in a Cloud workspace: the same kinds, in the same order, with the same names
/// and keys as `NewTabMenu` offers in a local one, minus what a machine cannot do yet.
struct CloudNewTabMenu: View {
    var session: CloudWorkspaceSession

    var body: some View {
        Menu {
            Button(PaneKind.chat.title, systemImage: PaneKind.chat.symbol) {
                Task { await session.newChat() }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!session.allows("prompt"))
            Button(PaneKind.terminal.title, systemImage: PaneKind.terminal.symbol) {
                session.open(.terminal)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!session.allows("terminal"))
            Divider()
            Button(PaneNaming.changes, systemImage: "plusminus") { session.open(.changes) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(PaneNaming.setup, systemImage: "hammer") { session.open(.setup) }
        } label: {
            Label("New Tab", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help("New tab in this Cloud workspace")
    }
}

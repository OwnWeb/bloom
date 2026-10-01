import SwiftUI
import BloomCore

/// A project-free conversation, drawn after the project groups.
struct ConversationSidebarRow: View {
    let chat: Session

    @Environment(AppModel.self) private var app
    @State private var isRenaming = false
    @State private var name = ""
    @State private var isConfirmingArchive = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let status = app.ask.status(for: chat.id)

        HStack(spacing: Metrics.spacing) {
            WorkspaceStatusGlyph(status: status)

            if isRenaming {
                TextField("Conversation name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: nameFocused) { had, has in
                        if had, !has, isRenaming { commitRename() }
                    }
                    .task { nameFocused = true }
            } else {
                Text(app.ask.title(for: chat))
                    .font(Typo.label)
                    .lineLimit(1)
                WorkspaceColourDot(
                    hex: app.ask.conversationColours[chat.id],
                    accessibilityName: app.ask.conversationColours[chat.id]
                        .flatMap { WorkspaceColour.named($0)?.name }
                )
            }

            Spacer(minLength: Metrics.spacingSmall)
            if app.ask.pinnedConversations.contains(chat.id) {
                Image(systemName: "pin.fill")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityLabel("Pinned")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") {
                name = app.ask.title(for: chat)
                isRenaming = true
            }
            Button(app.ask.pinnedConversations.contains(chat.id) ? "Unpin" : "Pin to Top") {
                Task { await app.ask.togglePin(chat.id) }
            }
            Menu("Colour") {
                Button("None") { Task { await app.ask.setColour(nil, for: chat.id) } }
                ForEach(WorkspaceColour.all) { colour in
                    Button(colour.name) {
                        Task { await app.ask.setColour(colour.hex, for: chat.id) }
                    }
                }
            }
            Button("Archive Conversation") {
                if app.ask.isRunning(chat.id) {
                    isConfirmingArchive = true
                } else {
                    Task { await app.ask.close(chat.id) }
                }
            }
        }
        .confirmationDialog(
            "Stop and archive this conversation?",
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible
        ) {
            Button("Stop and Archive", role: .destructive) {
                Task { await app.ask.close(chat.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent will stop. The transcript stays in Archived.")
        }
        .accessibilityLabel(app.ask.title(for: chat))
        .accessibilityValue(status == .clean ? "Idle" : status.label)
    }

    private func commitRename() {
        isRenaming = false
        Task { await app.ask.rename(chat.id, title: name) }
    }
}

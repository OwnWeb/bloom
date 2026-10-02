import SwiftUI
import BloomCore

/// A project-free conversation among Home's workspace rows.
struct HomeConversationRow: View {
    let conversation: Session
    let onArchive: () -> Void
    let onDelete: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.selection = conversation.archivedAt == nil
                ? .conversation(conversation.id)
                : .archivedConversation(conversation.id)
        } label: {
            HStack(spacing: Metrics.spacingWide) {
                Image(systemName: PaneGlyph.chat)
                    .foregroundStyle(Palette.textTertiary)
                VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                    Text(app.ask.title(for: conversation))
                        .font(Typo.labelEmphasis)
                    Text(conversation.archivedAt == nil
                         ? "Conversation · No project" : "Archived conversation")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
                WorkspaceColourDot(
                    hex: app.ask.conversationColours[conversation.id],
                    accessibilityName: nil
                )
                Spacer()
                if app.ask.pinnedConversations.contains(conversation.id) {
                    Image(systemName: "pin.fill")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .foregroundStyle(Palette.textPrimary)
            .frame(minHeight: HomeMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if conversation.archivedAt != nil {
                Button("Restore Conversation") {
                    Task { await app.ask.restore(conversation.id) }
                }
                Button("Delete…", role: .destructive, action: onDelete)
            } else {
                Button("Archive Conversation", action: onArchive)
            }
        }
    }
}

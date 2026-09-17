import BloomClient
import BloomCore
import SwiftUI

/// One Cloud workspace in the sidebar, drawn from runbloom.app's list alone, so a row never wakes
/// the machine it describes.
struct CloudWorkspaceRow: View {
    var item: CloudWorkspaceItem
    var isSelected: Bool

    private var status: CloudWorkspaceStatus { CloudWorkspaceStatus(item: item) }

    var body: some View {
        Label {
            HStack(spacing: Metrics.spacing) {
                Text(item.displayName)
                    .fontWeight(item.unread ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.canOpen {
                    // A team owner or admin can see a private workspace exists, and archive it,
                    // without being able to open it.
                    Image(systemName: "lock")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Palette.textInverted : Palette.textTertiary)
                        .help("Private to \(item.owner?.name ?? "its owner")")
                        .accessibilityLabel("Private to \(item.owner?.name ?? "its owner")")
                } else if item.sharedWithTeam || item.role == "collaborator" {
                    Image(systemName: "person.2")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Palette.textInverted : Palette.textTertiary)
                        .accessibilityLabel(item.role == "collaborator" ? "Shared with you" : "Shared with your team")
                }
                Spacer(minLength: Metrics.spacingSmall)
                if let diff = item.summary?.diff, diff.files > 0 {
                    Text("+\(diff.additions) −\(diff.deletions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? Palette.textInverted : Palette.textTertiary)
                }
            }
        } icon: {
            glyph
        }
        .help("\(item.project?.repository ?? item.displayBranch): \(status.phrase)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.phrase + (item.unread ? ", unread" : ""))
    }

    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .running, .settingUp, .stopping:
            Image(systemName: "cloud.fill")
                .foregroundStyle(isSelected ? Palette.textInverted : Palette.running)
                .symbolEffect(.pulse, options: .repeating)
        case .waiting:
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(isSelected ? Palette.textInverted : Palette.accent)
        case .setupFailed, .error:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(isSelected ? Palette.textInverted : Palette.negative)
        case .blocked:
            Image(systemName: "pause.circle")
                .foregroundStyle(isSelected ? Palette.textInverted : Palette.warning)
        case .asleep, .archiving:
            Image(systemName: "cloud")
                .foregroundStyle(isSelected ? Palette.textInverted : Palette.textTertiary)
        case .idle:
            Image(systemName: "cloud")
                .foregroundStyle(isSelected ? Palette.textInverted : Palette.textSecondary)
        }
    }
}

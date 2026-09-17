import BloomClient
import BloomCore
import SwiftUI

/// One Cloud workspace in the sidebar, drawn from runbloom.app's list alone, so a row never wakes
/// the machine it describes.
struct CloudWorkspaceRow: View {
    var item: CloudWorkspaceItem
    var isSelected: Bool

    /// What the machine is doing, for the sentence under the row and its tooltip.
    private var status: CloudWorkspaceStatus { CloudWorkspaceStatus(item: item) }
    /// The same fact in the sidebar's own vocabulary, for the mark. See `WorkspaceStatus`.
    private var mark: WorkspaceStatus { WorkspaceStatus(cloudItem: item) }

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

    /// The column's own mark, the one a local workspace wears, rather than a cloud of its own.
    /// Which section the row is in already says it runs in the cloud; the mark is for whether an
    /// agent is working, whether it wants a person, and what GitHub thinks of the branch.
    private var glyph: some View {
        WorkspaceStatusGlyph(status: mark, isOnSelection: isSelected)
    }
}

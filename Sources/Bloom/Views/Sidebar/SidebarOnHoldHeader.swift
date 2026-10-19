import SwiftUI
import BloomCore

/// The heading of the On hold section, set like Projects and Conversations because it is a third
/// section of the pane rather than a part of either. The chevron sits where Conversations has its
/// `+`, so the two line up.
struct SidebarOnHoldHeader: View {
    var count: Int
    var isFolded: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Metrics.spacingSmall) {
                Text("On hold")
                    .font(Typo.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textSecondary)
                Text(count.formatted(Figures.count))
                    .font(Typo.label)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: SidebarMetrics.caretSize, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                    .frame(width: Metrics.headerButton.width, height: Metrics.headerButton.height)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(count == 1 ? "On hold, 1 workspace" : "On hold, \(count) workspaces")
        .accessibilityValue(isFolded ? "Collapsed" : "Expanded")
    }
}

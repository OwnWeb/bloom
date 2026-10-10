import SwiftUI

/// The router's per-workspace checkbox, drawn the way the setup script's is beside it.
///
/// Here rather than in the composer's footer, for the reason `WorkspaceSetupOption` gives: the
/// footer qualifies the turn with controls that each pick a value, and this hands two of those
/// values to somebody else. It also has no room: `CreateWorkspaceView.width` is measured against
/// that row with its words on, and a seventh control would put every label back on the glyph rung.
struct WorkspaceRouterOption: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text("Choose the model automatically")
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text("Claude Haiku reads this message, not your code, and picks the model and effort before the conversation starts. Picking a model above turns this off.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .tint(Palette.controlAccent)
        .accessibilityHint("Turn off to start this workspace on the model and effort chosen above.")
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
    }
}

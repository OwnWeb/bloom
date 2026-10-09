import SwiftUI
import BloomCore

/// Above the composer while a draft starts with `!`: what pressing Return will do instead of
/// sending a message. The running command is drawn in the transcript, where its output will land,
/// rather than here. See `ShellCommandRowView` and `ShellCommand`.
struct ComposerShellModeHint: View {
    var draft: String

    var body: some View {
        if ShellCommand.isShellMode(draft) {
            Text("! for shell mode. Runs in the worktree, and the agent gets the output when it finishes.")
                .font(Typo.caption)
                .foregroundStyle(Palette.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.spacingSmall)
        }
    }
}

import SwiftUI
import BloomCore

/// Above the composer: what a `!` draft will do before it is sent, and the command's last lines
/// while it runs, with a way to stop it. The output goes to the agent as a message once the
/// command has finished, so this only has to show that it is alive. See `ShellCommand`.
struct ComposerShellRunView: View {
    var transcript: TranscriptModel
    var model: WorkspaceModel

    /// Enough to see a test runner moving, few enough not to push the transcript off the window.
    private static let visibleLines = 6

    var body: some View {
        if let run = transcript.shellRun {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                HStack(spacing: Metrics.spacing) {
                    ProgressView().controlSize(.small)
                    Text("$ \(run.command)")
                        .font(Typo.codeSmall)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Stop") { model.stopShellCommand(in: transcript) }
                        .help("Stop the command. Nothing is sent to the agent.")
                }
                if !run.output.isEmpty {
                    Text(run.output.recent(Self.visibleLines).joined(separator: "\n"))
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(Self.visibleLines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(Metrics.spacingSmall)
        } else if ShellCommand.command(in: transcript.draft) != nil {
            Text("Runs in the worktree. The agent gets the output when it finishes.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.spacingSmall)
        }
    }
}

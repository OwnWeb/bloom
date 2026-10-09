import SwiftUI
import BloomCore

/// A `!` command the user ran, drawn the way Claude Code draws one: the command after a `!`, and
/// what it printed under a `└`. Not a bubble, because the message under it is tags the reader never
/// typed and the output is a terminal's, which reads as one only in a fixed width face. See
/// `ShellCommand`.
///
/// The same drawing while the command runs, in the place its output will land, so the command is
/// on screen before anything typed after it: drawn above the composer instead, it was nowhere in
/// the conversation until it finished, under a reply to the message that came after it.
struct ShellCommandRowView: View {
    var command: String
    var output: String
    /// How it ended, or nil while it is still running.
    var status: String?
    var succeeded = true
    var onStop: (() -> Void)?

    /// About a screenful of a test run's summary. The rest is one click away.
    private static let collapsedLines = 10

    @State private var isExpanded = false

    init(sent: ShellCommand.Sent) {
        command = sent.command
        output = sent.output
        status = sent.status
        succeeded = sent.succeeded
    }

    init(running run: ShellCommand.Run, onStop: @escaping () -> Void) {
        command = run.command
        output = run.output.recent(Self.collapsedLines).joined(separator: "\n")
        self.onStop = onStop
    }

    private var isRunning: Bool { status == nil }

    private var lines: [String] {
        output.isEmpty ? [] : output.components(separatedBy: "\n")
    }

    private var shownLines: [String] {
        isExpanded ? lines : Array(lines.prefix(Self.collapsedLines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                Text("!").foregroundStyle(Palette.warning)
                Text(command).foregroundStyle(Palette.textPrimary)
                if isRunning {
                    ProgressView().controlSize(.small)
                    if let onStop {
                        Button("Stop", action: onStop)
                            .help("Stop the command. Nothing is sent to the agent.")
                    }
                }
            }
            .font(Typo.code)

            if !(isRunning && lines.isEmpty) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                    Text("└").foregroundStyle(Palette.textTertiary)
                    VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
                        if lines.isEmpty {
                            Text("(no output)").foregroundStyle(Palette.textSecondary)
                        } else {
                            Text(shownLines.joined(separator: "\n")).foregroundStyle(Palette.textSecondary)
                        }
                        if !isRunning, lines.count > Self.collapsedLines {
                            Button(isExpanded ? "Show less" : "Show all \(lines.count) lines") {
                                isExpanded.toggle()
                            }
                            .linkButton()
                        }
                        if let status, !succeeded {
                            Text("It \(status).").foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                .font(Typo.codeSmall)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
    }
}

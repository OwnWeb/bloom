import SwiftUI
import BloomCore

/// A `!` command the user ran, drawn the way Claude Code draws one: the command after a `!`, and
/// what it printed under a `└`. Not a bubble, because the message under it is tags the reader never
/// typed and the output is a terminal's, which reads as one only in a fixed width face. See
/// `ShellCommand`.
struct ShellCommandRowView: View {
    var sent: ShellCommand.Sent

    /// About a screenful of a test run's summary. The rest is one click away.
    private static let collapsedLines = 10

    @State private var isExpanded = false

    private var lines: [String] {
        sent.output.isEmpty ? [] : sent.output.components(separatedBy: "\n")
    }

    private var shownLines: [String] {
        isExpanded ? lines : Array(lines.prefix(Self.collapsedLines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                Text("!").foregroundStyle(Palette.warning)
                Text(sent.command).foregroundStyle(Palette.textPrimary)
            }
            .font(Typo.code)

            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                Text("└").foregroundStyle(Palette.textTertiary)
                VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
                    if lines.isEmpty {
                        Text("(no output)").foregroundStyle(Palette.textSecondary)
                    } else {
                        Text(shownLines.joined(separator: "\n")).foregroundStyle(Palette.textSecondary)
                    }
                    if lines.count > Self.collapsedLines {
                        Button(isExpanded ? "Show less" : "Show all \(lines.count) lines") {
                            isExpanded.toggle()
                        }
                        .linkButton()
                    }
                    if !sent.succeeded {
                        Text("It \(sent.status).").foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .font(Typo.codeSmall)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
    }
}

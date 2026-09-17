import SwiftUI
import BloomCore

/// The line that closes a compaction, and the one row in the transcript that is not a row.
///
/// **It is drawn as a rule across the pane rather than as another entry in the list, and that is
/// the whole point of it.** Everything above this line has left the model's head. A transcript
/// that draws the event as one more indented row, in the same column as a tool call and a
/// thought, hides exactly the thing that makes it matter: that the conversation above and the
/// conversation below are two different conversations as far as the agent is concerned. A date
/// separator is the shape the window already has for that, so this borrows it.
///
/// It deliberately leaves the glyph column, which every other row keeps. A row that lines up with
/// the rows around it reads as one of them, and this is a break between them.
///
/// Every figure on it is the CLI's own, off `compact_boundary`, and each one is dropped rather
/// than guessed at when the line did not carry it: see `ContextCompaction`, where the schema and
/// which fields are actually promised are written down.
struct CompactionBoundaryRowView: View {
    var compaction: ContextCompaction

    /// The glyph at rest, and the same one the working row breathes while the compaction runs, so
    /// the row a person watched for two minutes and the line it left behind are visibly the same
    /// event. See `StreamingStatusView.Mark.housekeeping`.
    static let symbol = "arrow.down.and.line.horizontal.and.arrow.up"

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            // A short stub before the stamp rather than none at all. With the stamp hard against
            // the pane's leading edge the rule reads as an underline of the row above it.
            rule.frame(width: TranscriptLayout.nestIndent)

            HStack(spacing: TranscriptLayout.tight) {
                Image(systemName: Self.symbol)
                    .font(Typo.caption)
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.trailing, TranscriptLayout.tight)

                Text("Compacted")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)

                if let size = compaction.sizeLabel() {
                    // Monospaced digits so a boundary drawn while the pane is resizing does not
                    // shuffle its own figures, and secondary rather than tertiary because the
                    // numbers are the only part of this line anybody reads twice.
                    Text(size)
                        .font(Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }

                if let duration = compaction.durationLabel {
                    Text("in \(duration)")
                        .font(Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .lineLimit(1)
            .fixedSize()

            rule
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.tight)
        .frame(minHeight: TranscriptLayout.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compaction.summary())
    }

    private var rule: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: Metrics.hairline)
    }
}

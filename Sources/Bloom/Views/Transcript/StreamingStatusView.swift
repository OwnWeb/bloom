import SwiftUI
import BloomCore

/// What the agent is doing when it has not said anything yet. A dot rather than a spinner when
/// there is no glyph to show, so an idle-looking turn still reads as alive.
struct StreamingStatusView: View {
    /// What is drawn in the glyph column, which is a question about what kind of waiting this is.
    enum Mark: Equatable {
        /// The agent is thinking and has said nothing yet: the window's own running dot.
        case activity
        /// The agent is running a tool: its symbol, in the running tint.
        case tool(String)
        /// **Not the agent answering you.** Compaction is the CLI tidying its own context so the
        /// turn can carry on, and for ninety seconds to two and a half minutes it is the only
        /// thing on screen. Drawn in tertiary ink rather than the running blue, because the blue
        /// is a promise that an answer is coming, and breathing on the window's heartbeat rather
        /// than pulsing, because it is housekeeping rather than progress. See `ContextCompaction`
        /// for the measurements and for what the CLI actually reports while this is on screen,
        /// which is nothing at all.
        case housekeeping(String)
    }

    var mark: Mark
    var text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            glyph

            Text(text)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .transcriptRowFrame()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private var glyph: some View {
        switch mark {
        case .activity:
            ActivityDot(isActive: true)
                .frame(width: TranscriptLayout.glyphWidth)

        case .tool(let symbol):
            TranscriptGlyph(symbol: symbol, tint: Palette.running)

        case .housekeeping(let symbol):
            // The same mechanism the retry row uses, and for the same reason: a `CAAnimation` on
            // a layer keeps moving when the window is behind another app, which is where a two
            // minute wait is usually spent. See `BreathingMark`.
            BreathingMark(isMoving: !reduceMotion) {
                TranscriptGlyph(symbol: symbol, tint: Palette.textTertiary)
            }
        }
    }
}

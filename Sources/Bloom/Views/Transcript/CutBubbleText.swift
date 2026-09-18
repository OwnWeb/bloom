import SwiftUI

/// A bubble's words, cut to a few lines and faded into the bubble's own fill.
///
/// Both workspace message bubbles hold a brief written for another agent, which is the one thing
/// in this transcript with no length anybody agreed to: a dozen paragraphs arrive as often as a
/// sentence does, and drawn whole they fill the pane and push what the agent did about them off
/// the bottom. So each is cut, the sending chat at three lines and the receiving one at five, and
/// this is the cut both of them make.
///
/// **SwiftUI will not say whether it truncated.** There is no callback and no environment value
/// for it, so the only way to know is to lay the same string out twice: once with the line limit
/// and once without, at the same width, and compare the heights. The unlimited copy is the `ruler`
/// below, hidden, in a background, which is how it gets that width without claiming any space of
/// its own. It is laid out only while the text is cut, so opening a message does not take away the
/// control that closes it again.
///
/// **The fade is one line tall and stops short of the fill.** It is measured as the drawn height
/// divided by the line limit rather than from the font, which costs nothing and follows the text
/// size and line spacing settings for free. It stops at `Self.fadeOpacity` rather than at the fill
/// because `Text` has already truncated with an ellipsis and a gradient that reaches the fill
/// erases it: the reader is meant to see both, the soft edge saying there is more and the ellipsis
/// saying so in the text itself.
struct CutBubbleText: View {
    var text: String
    /// How many lines survive the cut.
    var lines: Int
    var ink: Color
    /// What the last line fades into, which is whatever is drawn behind this text. The queued
    /// bubble has no fill of its own, so it passes the transcript's ground instead.
    var fill: Color
    var isExpanded: Bool
    /// Whether anything was actually cut, which is what the row hangs its "Show all" on. Written
    /// only while cut, so it keeps saying yes once the reader has opened the message.
    @Binding var isCut: Bool

    @State private var drawnHeight: CGFloat = 0
    @State private var wholeHeight: CGFloat = 0

    /// Enough to soften the last line, not enough to take the ellipsis with it.
    private static let fadeOpacity: Double = 0.72

    var body: some View {
        Text(text)
            .font(Typo.body)
            .foregroundStyle(ink)
            .textSelection(.enabled)
            .lineLimit(isExpanded ? nil : lines)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                drawnHeight = $0
                measure()
            }
            .background(alignment: .topLeading) { ruler }
            .padding(UserTurnRowView.padding)
            .overlay(alignment: .bottom) { fade }
    }

    /// The same text with no line limit, at the width the cut one was given, so the two heights say
    /// whether anything was cut. A background is sized to the content it is behind, and `fixedSize`
    /// vertically lets the ruler run past it rather than be clamped, which is the same arrangement
    /// `TruncationProbe` uses for a single line.
    @ViewBuilder
    private var ruler: some View {
        if !isExpanded {
            Text(text)
                .font(Typo.body)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    wholeHeight = $0
                    measure()
                }
        }
    }

    /// Over the last line and the padding under it, so the softening runs all the way to the
    /// bubble's edge rather than stopping at the text and leaving a hard band below it.
    @ViewBuilder
    private var fade: some View {
        if isCut, !isExpanded, drawnHeight > 0, lines > 0 {
            LinearGradient(
                colors: [fill.opacity(0), fill.opacity(Self.fadeOpacity)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: drawnHeight / CGFloat(lines) + UserTurnRowView.padding.bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Half a point of slack, because the two heights come from two layouts of the same string.
    private func measure() {
        guard !isExpanded, drawnHeight > 0, wholeHeight > 0 else { return }
        let cut = wholeHeight > drawnHeight + 0.5
        if cut != isCut { isCut = cut }
    }
}

import Foundation

/// When a pane holds its transcript back, and what it measures when it reflows.
///
/// **The measurement behind both halves.** A transcript row's height is only known once SwiftUI
/// has laid it out at a width, which is about a tenth of a millisecond a row on a kept hosting
/// controller (see `TranscriptTable.Coordinator.measure`), and there are two moments that ask for
/// a great many of them at once.
///
/// **An arrival.** Pointing a pane at another conversation used to measure the whole window it
/// opened: the tail, and a beat later the four hundred rows behind it. None of that is measured up
/// front any more (see `TranscriptRowHeights.assumed`), so what is left is reading the rows and
/// measuring the one screen the reader actually lands on. Until that has happened the pane is a
/// transcript in pieces, so it is not drawn at all until it is in the place it belongs, and then
/// it is faded in.
///
/// **A split** is an arrival too: `CenterPanesView` deliberately changes a pane's `ForEach`
/// identity when a tab goes from one pane to two, so the chat is rebuilt rather than resized.
///
/// **A table resize is not held here.** Its visible rows reflow whenever its own width changes,
/// which still happens during a window resize or an inner chat split drag. The outer window split
/// now holds the whole centre host at one width while either outer divider moves, then crossfades
/// the final layout. That avoids repeatedly laying out the whole SwiftUI column during a drag.
/// `eager` below is measured once the table's width has stopped moving.
public enum TranscriptPaneHold {
    /// How far the width has to move from the last reflow before a resize reflows on the frame.
    ///
    /// A slow drag moves the pane a point or two a frame, and a reflow for each of those rewraps
    /// almost nothing while paying for every row on screen. Below this the rows keep the heights
    /// of the last reflow for a few frames, so a paragraph that gained a line draws into the row
    /// under it until the next step or the settle. The previous eight-point step remeasured the
    /// visible screen and repositioned the end on nearly every frame of a divider drag. Sixteen
    /// points still catches a wrap within about two body characters, while giving adjacent width
    /// changes the same cached row heights.
    public static let reflowStep: Double = 16

    /// Whether a width this far from the last reflow is reflowed now rather than at the settle.
    public static func reflowsNow(from reflowed: Double, to width: Double) -> Bool {
        abs(width - reflowed) >= reflowStep
    }

    /// How long the width has to be still before the resize is finished: the reflow a slow drag
    /// skipped, if it skipped one, and the margin around the screen. See `eager`.
    public static let settle: Duration = .milliseconds(150)

    /// The longest a pane stays blank waiting for the conversation it has been pointed at.
    ///
    /// **What it is showing meanwhile is its own empty ground and never another conversation**, so
    /// this is a backstop rather than a length anybody watches: the pane is revealed the moment its
    /// rows are in and in the right place, which is a load from SQLite and a tail's worth of
    /// measuring away. This is what covers a load that never returns, a task cancelled on its way
    /// there, and a session with nothing in it at all.
    public static let arrival: Duration = .seconds(1)

    /// The most rows measured either side of the ones on screen.
    ///
    /// A margin so that a small scroll after a resize does not land on an estimate, and a cap so
    /// that a pane full of empty rows cannot decide to measure a whole conversation.
    public static let margin = 120

    /// The rows measured exactly once a reflow has settled, given the rows the pane can see.
    ///
    /// Everything visible is in it, always: a row drawn at a height measured for another width is
    /// a gap or an overlap the reader is looking at. Every other row keeps its old height as an
    /// estimate until it is drawn.
    public static func eager(visible: Range<Int>, count: Int) -> Range<Int> {
        guard count > 0, !visible.isEmpty else { return 0..<0 }
        let reach = min(visible.count, margin)
        let lower = max(0, visible.lowerBound - reach)
        let upper = min(count, visible.upperBound + reach)
        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }
}

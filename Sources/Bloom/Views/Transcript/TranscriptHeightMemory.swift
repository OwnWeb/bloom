import BloomCore

/// Row measurements belong to a conversation and pane, not to one table view. Switching to a
/// tool tab destroys the table, and measuring rows again cost 128 to 152 ms on
/// a 2,608 row conversation in `TabProbe`. The core cache already bounds its rows and invalidates
/// measurements when text settings or width change; this box lets a new table keep using it.
@MainActor
final class TranscriptHeightMemory {
    var heights = TranscriptRowHeights()

    /// `TranscriptRowHeights.Measure` tracks size and leading, but the selected typeface is a
    /// SwiftUI value. A font changed while this chat's table was absent must invalidate it too.
    var chatFont: ChatFont?
}

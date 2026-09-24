import Foundation

/// Chooses the next older rows to measure while the reader is idle.
///
/// A row costs most on its first layout. Measuring older rows after the conversation appears
/// moves that cost off the reader's first upward scroll. Each pass is bounded so a hand on the
/// trackpad can interrupt the work between rows. Rows already measured do not consume the cap,
/// or the first batch would be picked again instead of progressing through the history.
public enum TranscriptWarming {
    /// About a screen of ordinary rows. The view yields between rows and pauses between batches.
    public static let mostRows = 60
    /// Bound idle work on very long transcripts. Another settle after scrolling prepares the
    /// next stretch, so the first visit need not measure an entire day of conversation.
    public static let lookbackRows = 4_000

    /// Nearest first, because these are the rows an upward scroll reaches first.
    public static func nextBatch(
        in range: Range<Int>, most: Int = mostRows, needsMeasurement: (Int) -> Bool
    ) -> [Int] {
        guard most > 0 else { return [] }
        var picked: [Int] = []
        for row in range.reversed() where needsMeasurement(row) {
            picked.append(row)
            if picked.count == most { break }
        }
        return picked
    }
}

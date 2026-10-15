import Foundation

/// When a press that moved while held is a drag rather than a click.
///
/// A link pressed with a hand that shifted by a point did not open, because any movement at all
/// counted as a drag. A press elsewhere in a row has to go further still, since it may be on a
/// button, and a button's click is lost the moment its press becomes a selection.
public enum TranscriptDrag: Sendable, Hashable {
    /// A press on selectable text, where a click opens a link and a drag selects.
    case text
    /// A press anywhere else in a row: empty space, an icon, a button.
    case row

    /// How far the pointer may move, in points, and still be clicking.
    public var slop: Double {
        switch self {
        case .text: 4
        case .row: 12
        }
    }

    public func leavesClick(dx: Double, dy: Double) -> Bool {
        (dx * dx + dy * dy).squareRoot() > slop
    }
}

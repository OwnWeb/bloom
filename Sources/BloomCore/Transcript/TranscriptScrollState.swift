import Foundation

/// The reader's place in a transcript pane, held as state so that it is never re-read from a clip
/// view origin that a resize, a clamp or a stale replay has already moved.
public struct TranscriptScrollState: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        case end
        /// Where a reader left the view: a row and `TranscriptAnchor.delta` into it.
        case row(TranscriptEntryID, delta: Double)
        /// A navigation aimed by a unit point, resolved again on every pass because the row's
        /// height is corrected after it is drawn (an unfolded setup log is thousands of points).
        case aimed(TranscriptEntryID, anchor: Double)
    }

    public enum Event: Equatable, Sendable {
        /// Opening, the jump pill, a search, a fold, `goToEnd`.
        case navigated(Place)
        /// Any move of the clip view, with the place read from it and whoever was writing.
        case clipMoved(to: Place, by: TranscriptClipMove.Writers)
    }

    public struct RowFrame: Equatable, Sendable {
        public var top: Double
        public var height: Double

        public init(top: Double, height: Double) {
            self.top = top
            self.height = height
        }
    }

    public struct Geometry {
        public var contentHeight: Double
        public var viewportHeight: Double
        public var frame: (TranscriptEntryID) -> RowFrame?

        public init(
            contentHeight: Double,
            viewportHeight: Double,
            frame: @escaping (TranscriptEntryID) -> RowFrame?
        ) {
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
            self.frame = frame
        }
    }

    public private(set) var place: Place

    public init(place: Place = .end) {
        self.place = place
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .navigated(let place):
            self.place = place
        case .clipMoved(let place, let writers):
            // A move made while geometry was changing is never a gesture, even under the hand.
            guard writers == .reader else { return }
            self.place = place
        }
    }

    /// The clip view origin this place resolves to, or nil when nothing should be written: a pane
    /// with no height, or a row that is not in the table. The place is kept either way.
    public func origin(in geometry: Geometry) -> Double? {
        guard TranscriptAnchor.canPlace(viewportHeight: geometry.viewportHeight),
              let target = target(in: geometry) else { return nil }
        return TranscriptAnchor.clamped(
            target, contentHeight: geometry.contentHeight, viewportHeight: geometry.viewportHeight
        )
    }

    /// The one reading of a clip view origin, made after a reader's gesture. Nil from a pane with
    /// no height, where the end is the whole content and any row is a guess.
    public static func read(
        offset: Double, topRow: TranscriptEntryID?, in geometry: Geometry
    ) -> Place? {
        guard TranscriptAnchor.canPlace(viewportHeight: geometry.viewportHeight) else { return nil }
        let isAtEnd = TranscriptAnchor.isAtEnd(
            offset: offset, contentHeight: geometry.contentHeight, viewportHeight: geometry.viewportHeight
        )
        if isAtEnd { return .end }
        guard let topRow, let frame = geometry.frame(topRow) else { return nil }
        return .row(topRow, delta: TranscriptAnchor.delta(rowTop: frame.top, viewportTop: offset))
    }

    private func target(in geometry: Geometry) -> Double? {
        switch place {
        case .end:
            return TranscriptAnchor.end(
                contentHeight: geometry.contentHeight, viewportHeight: geometry.viewportHeight
            )
        case .row(let id, let delta):
            guard let frame = geometry.frame(id) else { return nil }
            return TranscriptAnchor.offset(rowTop: frame.top, delta: delta)
        case .aimed(let id, let anchor):
            guard let frame = geometry.frame(id) else { return nil }
            return TranscriptAnchor.offset(
                rowTop: frame.top,
                rowHeight: frame.height,
                viewportHeight: geometry.viewportHeight,
                anchor: anchor
            )
        }
    }
}

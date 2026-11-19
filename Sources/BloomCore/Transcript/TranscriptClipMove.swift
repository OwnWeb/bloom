import Foundation

/// A movement of the transcript's clip view, and whether anything known to write it was writing.
///
/// The view was thrown up by moves nobody could name afterwards: three writers share one origin
/// and the log only said where it ended up. A move nobody claims is the jump being looked for.
public enum TranscriptClipMove {
    /// Who was writing the clip view when it moved, sampled at the bounds change itself.
    public struct Writers: OptionSet, Sendable, CustomStringConvertible {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// The table's own placement.
        public static let table = Writers(rawValue: 1 << 0)
        /// A frame of the live end follower.
        public static let follower = Writers(rawValue: 1 << 1)
        /// AppKit keeping the origin inside a document that is changing size.
        public static let documentResize = Writers(rawValue: 1 << 2)
        /// The pane itself changing size.
        public static let viewportResize = Writers(rawValue: 1 << 3)
        /// A wheel, a trackpad or the scroller under a hand.
        public static let reader = Writers(rawValue: 1 << 4)

        private static let names: [(Writers, String)] = [
            (.table, "table"), (.follower, "follower"), (.documentResize, "document"),
            (.viewportResize, "viewport"), (.reader, "reader")
        ]

        public var description: String {
            let held = Self.names.filter { contains($0.0) }.map(\.1)
            return held.isEmpty ? "nobody" : held.joined(separator: "+")
        }
    }

    /// The smallest move worth a line. Under it is a height correction rounding the origin.
    public static let slack: Double = 8

    public static func isUnexplained(from: Double, to: Double, writers: Writers) -> Bool {
        writers.isEmpty && abs(to - from) > slack
    }

    /// Whether a key scrolls a table through the responder chain. The log says only this about a
    /// key, never which one it was.
    public static func isScrollKey(_ keyCode: UInt16) -> Bool {
        ScrollKey(rawValue: keyCode) != nil
    }

    private enum ScrollKey: UInt16 {
        case space = 49
        case home = 115
        case pageUp = 116
        case end = 119
        case pageDown = 121
        case downArrow = 125
        case upArrow = 126
    }

    /// One line a window, and a count of the ones kept back: paging by keyboard and a selection
    /// dragged past the edge move the view many times a second with nobody to claim them.
    public struct Budget: Sendable {
        public static let window: Double = 1

        private var lastSaid: Double?
        private var unsaid = 0

        public init() {}

        /// How many moves went unsaid since the last line, or nil when this one stays unsaid too.
        public mutating func spend(at now: Double) -> Int? {
            if let lastSaid, now - lastSaid < Self.window {
                unsaid += 1
                return nil
            }
            lastSaid = now
            defer { unsaid = 0 }
            return unsaid
        }
    }
}

import AppKit
import BloomCore
import QuartzCore

/// What a transcript log line says about the moment it was written.
///
/// An end let go by position, or by the follower, could not be told from a reader paging by
/// keyboard: a key scrolls the table through the responder chain and nothing in this app sees it.
@MainActor
enum TranscriptScrollEvidence {
    private static let millisecondsPerSecond = 1_000.0

    /// The app's last event as a kind and an age. A key is only ever "scroll key" or "key".
    static func lastEvent() -> String {
        guard let event = NSApp.currentEvent else { return "none" }
        let age = Int((ProcessInfo.processInfo.systemUptime - event.timestamp) * millisecondsPerSecond)
        let kind = switch event.type {
        case .keyDown, .keyUp: TranscriptClipMove.isScrollKey(event.keyCode) ? "scroll key" : "key"
        case .scrollWheel: "wheel"
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: "mouse"
        default: "event \(event.type.rawValue)"
        }
        return "\(kind) \(age)ms ago"
    }

    /// Milliseconds since a `CACurrentMediaTime` stamp.
    static func age(of stamp: CFTimeInterval) -> Int {
        Int((CACurrentMediaTime() - stamp) * millisecondsPerSecond)
    }
}

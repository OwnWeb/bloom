import AppKit
import BloomCore
import SwiftUI

/// Lets a selection start anywhere in a row, as it does in any document, not only on its prose.
///
/// Only the prose is AppKit text that selects. A press anywhere else, empty space, a button, an
/// icon, a caption, lands on the hosting view and selected nothing. A drag from there is handed to
/// the nearest prose in the table, which may be in another row when this one has none, such as a
/// folded run of tool calls.
///
/// SwiftUI owns the press until it is released, so the hand over is deferred to keep the tracking
/// loop out of SwiftUI's gesture callback. When it ends, the release is handed back far outside
/// the window: SwiftUI still needs one to finish the press, and one outside a button cancels it
/// rather than pressing it.
@MainActor
enum TranscriptDragSelection {
    static func takeOver(_ drag: DragGesture.Value) {
        guard !isTakingOver, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              let window = event.window else { return }
        let press = NSPoint(
            x: event.locationInWindow.x - drag.translation.width,
            y: event.locationInWindow.y + drag.translation.height
        )
        guard let hit = window.contentView?.hitTest(press),
              let target = nearestText(to: press, from: hit),
              let down = mouseEvent(.leftMouseDown, at: press, in: window),
              let up = mouseEvent(.leftMouseUp, at: releaseOutsideWindow, in: window) else { return }
        isTakingOver = true
        Task { @MainActor in
            target.mouseDown(with: down)
            window.postEvent(up, atStart: true)
            isTakingOver = false
        }
    }

    private static var isTakingOver = false
    private static let releaseOutsideWindow = NSPoint(x: -100_000, y: -100_000)

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        )
    }

    private static func nearestText(to point: NSPoint, from view: NSView) -> LinkTextView? {
        var table: NSView? = view
        while let current = table, !(current is NSTableView) { table = current.superview }
        guard let table else { return nil }
        return textViews(in: table)
            .filter { !$0.isHidden }
            .min { $0.squaredDistance(fromWindowPoint: point) < $1.squaredDistance(fromWindowPoint: point) }
    }

    private static func textViews(in view: NSView) -> [LinkTextView] {
        view.subviews.flatMap { child -> [LinkTextView] in
            if let text = child as? LinkTextView { return [text] }
            return textViews(in: child)
        }
    }
}

extension View {
    /// A drag that starts anywhere in this row selects the transcript's text.
    func selectsTranscriptTextWhenDragged() -> some View {
        contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: TranscriptDrag.row.slop).onChanged(TranscriptDragSelection.takeOver)
            )
    }
}

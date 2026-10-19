import AppKit
import SwiftUI

/// The empty space above On hold that keeps it at the foot of a short pane, and gives way to
/// nothing once the pane scrolls, so it is never pinned.
///
/// **Read from AppKit, because SwiftUI never sees the list get shorter.** The table under the list
/// always fills the visible height, so `onScrollGeometryChange` reports a content size that grows
/// but never shrinks: folding On hold left its rows' height standing empty under the heading. The
/// last row's rect is the real height.
///
/// Found the way `SidebarKeyboardFocus` finds the table, by position, for the reason given there.
struct SidebarOnHoldGap: NSViewRepresentable {
    var gap: CGFloat
    /// Whether the section is drawn. Without its heading in the table there is no gap to subtract.
    var isShown: Bool
    /// Whether the last row is the heading rather than a workspace, which is the only row a held
    /// workspace's height can be read from.
    var isFolded: Bool
    var onChange: (SidebarOnHoldRoom) -> Void

    func makeNSView(context: Context) -> SidebarOnHoldGapView { SidebarOnHoldGapView() }

    /// Called on every update of the sidebar, which is every time a row arrives, leaves or folds.
    func updateNSView(_ view: SidebarOnHoldGapView, context: Context) {
        view.gap = gap
        view.isShown = isShown
        view.isFolded = isFolded
        view.onChange = onChange
        view.scheduleMeasure()
    }

    static func dismantleNSView(_ view: SidebarOnHoldGapView, coordinator: ()) {
        view.stopObserving()
    }
}

/// What the probe measured: the room left below the content, without the gap, and how tall a row
/// is. The row height is what lets a fold move the gap in the same update as its rows, instead of
/// a turn later, which drew the heading jumping after the rows had already gone.
struct SidebarOnHoldRoom: Equatable {
    var free: CGFloat = 0
    var rowHeight: CGFloat = 0

    var gap: CGFloat { max(0, free) }

    /// The room after `rows` workspace rows appear, or disappear when negative.
    func adding(rows: Int) -> Self {
        Self(free: free - CGFloat(rows) * rowHeight, rowHeight: rowHeight)
    }
}

@MainActor
final class SidebarOnHoldGapView: NSView {
    var gap: CGFloat = 0
    var isShown = false
    var isFolded = true
    var onChange: ((SidebarOnHoldRoom) -> Void)?

    private var reported = SidebarOnHoldRoom()
    /// What the table draws below its last row. Only readable while the table is taller than the
    /// room, because a table that fits is stretched to the room's height. Left out, the list ran
    /// that many points past the bottom and drew a scroller over a pane with nothing to scroll.
    private var bottomPadding: CGFloat = 0
    /// The room's height at the last measure, which a live resize moves the gap from.
    private var lastVisible: CGFloat?

    /// Below this, a difference is layout rounding rather than something to act on.
    private static let tolerance: CGFloat = 0.5

    private weak var observedClip: NSClipView?
    private var resizeObserver: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        scheduleMeasure()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleMeasure()
    }

    func stopObserving() {
        resizeObserver.map(NotificationCenter.default.removeObserver)
        resizeObserver = nil
        observedClip = nil
    }

    /// A turn later, once the table has taken the update that asked for it, and never inside a
    /// SwiftUI pass. See `SidebarKeyboardFocusView.scheduleRefresh`.
    /// Not during a live resize, which `follow` answers instead.
    func scheduleMeasure() {
        guard !inLiveResize else { return }
        Task { @MainActor [weak self] in self?.measure() }
    }

    private func measure() {
        guard isShown else { return report(SidebarOnHoldRoom(rowHeight: reported.rowHeight)) }
        guard let table = sidebarTable(), let scroll = table.enclosingScrollView, table.numberOfRows > 0 else {
            return
        }
        observeResize(of: scroll.contentView)

        let visible = Self.visibleHeight(of: scroll)
        lastVisible = visible
        let last = table.rect(ofRow: table.numberOfRows - 1)
        if table.frame.height > visible + Self.tolerance { bottomPadding = max(0, table.frame.height - last.maxY) }
        // The gap is inside the heading's row, so it is taken back out to get the content's own height.
        let content = last.maxY - gap + bottomPadding
        // Folded, the heading's own height stands in until a workspace row has been seen: both
        // come out at the list's row pitch.
        let rowHeight = isFolded ? (reported.rowHeight > 0 ? reported.rowHeight : last.height - gap) : last.height
        report(SidebarOnHoldRoom(free: visible - content, rowHeight: rowHeight))
    }

    /// While the window is being dragged the rows stay as they are and only the room changes, so
    /// the gap moves by exactly what the room did, in the same pass. Measuring the table instead
    /// read its frame halfway through the resize and sent the heading down, up and down again.
    private func follow(_ scroll: NSScrollView) {
        let visible = Self.visibleHeight(of: scroll)
        defer { lastVisible = visible }
        guard isShown, let lastVisible else { return }
        report(SidebarOnHoldRoom(free: reported.free + visible - lastVisible, rowHeight: reported.rowHeight))
    }

    private static func visibleHeight(of scroll: NSScrollView) -> CGFloat {
        scroll.contentView.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom
    }

    private func sidebarTable() -> NSTableView? {
        let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        return window?.contentView.flatMap { SidebarKeyboardFocusView.table(under: $0, covering: centre) }
    }

    private func report(_ room: SidebarOnHoldRoom) {
        defer { reported = room }
        let moved = abs(room.gap - gap) > Self.tolerance || abs(room.rowHeight - reported.rowHeight) > Self.tolerance
        guard moved else { return }
        onChange?(room)
    }

    /// The window growing or shrinking changes the room without changing a row.
    private func observeResize(of clip: NSClipView) {
        guard observedClip !== clip else { return }
        stopObserving()
        observedClip = clip
        // No queue, so the gap follows in the same pass as the resize rather than a turn behind it.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scroll = self.observedClip?.enclosingScrollView else { return }
                if self.inLiveResize { self.follow(scroll) } else { self.scheduleMeasure() }
            }
        }
    }
}

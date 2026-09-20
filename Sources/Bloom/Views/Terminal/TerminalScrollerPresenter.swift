import AppKit
import SwiftTerm

/// A terminal's scroll bar the way the system draws every other one: following the "Show scroll
/// bars" setting, and with the overlay style there only while it is wanted.
///
/// **What the strip was.** SwiftTerm puts a bare `NSScroller` beside its text rather than inside an
/// `NSScrollView`. An overlay scroller fades by itself only when a scroll view drives it, so this
/// one stood there permanently, and in its lane down the right of every pane that was the grey
/// strip the owner kept seeing. His decision: native, which never has a permanent strip.
///
/// **So this does what a scroll view would.** The style is `NSScroller.preferredScrollerStyle`,
/// followed when the setting changes. In the overlay style the knob is invisible at rest, shown
/// while the reader scrolls or has the pointer in its lane, and faded a moment after, which is the
/// system's own rhythm. In the legacy style, "Always" in System Settings, it stays: a permanent
/// bar is what that reader asked the system for.
///
/// **Faded with `alphaValue`, never hidden.** SwiftTerm narrows the text by the scroller's width
/// unless the scroller is hidden, so hiding it would resize the terminal, reflow it and tell the
/// shell a new width every time the knob appeared. An invisible scroller keeps its place, its
/// clicks and its drags, so the scroll position works exactly as before. The lane it keeps is
/// painted the terminal's own background (`applyBloomColours`), so at rest there is nothing to see.
///
/// SwiftTerm's `scrollWheel` and `mouseMoved` are `public` rather than `open`, so a subclass cannot
/// hear them. A local event monitor hears the wheel, and a tracking area over the lane hears the
/// pointer.
@MainActor
final class TerminalScrollerPresenter: NSObject {
    private weak var terminal: SwiftTerm.TerminalView?
    private var styleObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var wheelMonitor: Any?
    private var lane: NSTrackingArea?
    private var isPointerInLane = false
    private var fade: Task<Void, Never>?

    /// How long the knob stays after the last sign of the reader, which is about what AppKit's own
    /// overlay scrollers keep. A matter of feel, not of correctness.
    private static let linger: Duration = .milliseconds(900)

    init(terminal: SwiftTerm.TerminalView) {
        self.terminal = terminal
        super.init()
        styleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyStyle() }
        }
        terminal.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: terminal, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackLane() }
        }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.wheel(event) }
            return event
        }
        applyStyle()
        trackLane()
    }

    isolated deinit {
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        fade?.cancel()
    }

    var scroller: NSScroller? { terminal?.subviews.lazy.compactMap { $0 as? NSScroller }.first }

    /// Whether the knob is drawn at rest, which is only in the legacy style.
    var isOverlay: Bool { terminal?.scrollerStyle == .overlay }

    func applyStyle() {
        guard let terminal else { return }
        let preferred = NSScroller.preferredScrollerStyle
        if terminal.scrollerStyle != preferred { terminal.scrollerStyle = preferred }
        fade?.cancel()
        scroller?.alphaValue = preferred == .overlay ? 0 : 1
        trackLane()
    }

    /// Shows the knob and fades it after `linger`, unless the pointer is still in its lane.
    func flash() {
        guard isOverlay, let scroller else { return }
        fade?.cancel()
        if scroller.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                scroller.animator().alphaValue = 1
            }
        }
        guard !isPointerInLane else { return }
        fade = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard isOverlay, !isPointerInLane, let scroller else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            scroller.animator().alphaValue = 0
        }
    }

    private func wheel(_ event: NSEvent) {
        guard let terminal, event.window === terminal.window,
              terminal.bounds.contains(terminal.convert(event.locationInWindow, from: nil)) else { return }
        flash()
    }

    /// The lane the scroller stands in, so a pointer arriving there shows it and a drag keeps it.
    private func trackLane() {
        guard let terminal else { return }
        if let lane { terminal.removeTrackingArea(lane) }
        // From the terminal's bounds rather than the scroller's frame, which Auto Layout has not
        // set yet when the view is first made.
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: terminal.scrollerStyle)
        let bounds = terminal.bounds
        let area = NSTrackingArea(
            rect: CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height),
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        terminal.addTrackingArea(area)
        lane = area
    }

    @objc func mouseEntered(with event: NSEvent) {
        isPointerInLane = true
        flash()
    }

    @objc func mouseExited(with event: NSEvent) {
        isPointerInLane = false
        flash()
    }
}

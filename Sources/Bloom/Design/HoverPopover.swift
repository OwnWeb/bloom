import AppKit
import SwiftUI

/// A card that opens while the pointer rests on something, as a popover, and closes when it leaves.
///
/// ```swift
/// row
///     .hoverPopover(id: workspace.id, arrowEdge: .trailing) {
///         WorkspaceHoverCardView(card: card, isInPopover: true)
///     }
/// ```
///
/// **One of these for the whole window, so every hover card in it behaves alike.** The sidebar's
/// workspace card and the pull request band's were a borderless panel placed by hand, with a
/// shadow invalidated after every resize, while the transcript's tool row card beside them was a
/// popover. The owner asked for the popover and for it to be a component, so a new hover card is a
/// modifier rather than a third mechanism. `TranscriptHoverOverlay` is still its own: its chips
/// sit in a lazy list and report their frames up, and its file card has to be measured before it
/// opens, which is a different problem from a view that can carry its own popover.
///
/// What it does, in one place:
///
/// - **Waits** `Motion.hoverCardDelay` before opening, the window's one answer to whether a pointer
///   is resting on something or crossing it.
/// - **One card at a time.** Arriving on something else closes whatever is up, rather than
///   leaving the old card standing while the new one waits out its delay.
/// - **A dismissal sticks.** A card closed by a click or a scroll does not reopen under a pointer
///   that has not moved: the pointer has to leave and arrive again.
/// - **Closes on everything listed on `watchForDismissal()`**: a click anywhere, a scroll, a menu,
///   a sheet, the window losing key. The click is delivered as well; the monitor only watches.
/// - **Closes when the view leaves**, which a row archived or filtered out under a stationary
///   pointer needs, because no exit ever arrives for it.
///
/// AppKit places the popover, including the flip to the other side when there is no room on
/// `arrowEdge`'s. It takes no clicks of its own: a click anywhere closes it and reaches whatever
/// was under the pointer, which is the one way it differs from SwiftUI's `.popover`.
extension View {
    /// - Parameters:
    ///   - id: what this card is about. Two surfaces with a card about the same thing need
    ///     different ids, or moving from one to the other reads as the pointer never having moved.
    ///   - delay: how long the pointer rests before the card opens. `Motion.hoverCardDelay` unless a
    ///     surface has a reason to wait longer, as the sidebar does.
    ///   - isEnabled: asked at the end of the wait, not at the start, so a state that changed
    ///     while the pointer rested (a row going into rename) is the one that decides.
    ///   - content: the card. Built when the popover opens, so it is current then.
    func hoverPopover<ID: Hashable, Content: View>(
        id: ID,
        arrowEdge: Edge = .bottom,
        delay: Duration = Motion.hoverCardDelay,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let key = AnyHashable(id)
        return self
            // An `NSPopover` of our own rather than SwiftUI's `.popover`, and that is the fix for
            // "selecting a workspace now takes two clicks". SwiftUI's popover is TRANSIENT: AppKit
            // closes it on the next click outside it and swallows that click to do so, and the
            // pointer is still on the row when the row is clicked, so the card was still up and
            // the click only closed it. The transcript's card never showed this because its chips
            // close their card on the way out, before any click. This one is `.applicationDefined`,
            // which AppKit never closes on its own and so never eats a click for: the mouse-down
            // monitor on the presenter closes it and hands the same click on to the row.
            //
            // On a background, so it does not share a modifier chain with a popover the view
            // already carries, such as a row's archive confirmation.
            .background {
                HoverPopoverAnchor(
                    isPresented: HoverPopoverPresenter.shared.isPresenting(key),
                    arrowEdge: arrowEdge,
                    content: content,
                    onClose: { HoverPopoverPresenter.shared.pointerExited(key) }
                )
            }
            .onHover { inside in
                if inside {
                    HoverPopoverPresenter.shared.pointerEntered(key, delay: delay, isEnabled: isEnabled)
                } else {
                    HoverPopoverPresenter.shared.pointerExited(key)
                }
            }
            .onDisappear { HoverPopoverPresenter.shared.pointerExited(key) }
    }
}

/// When the one hover card in the window opens and closes. Drawn by `hoverPopover`; call this
/// directly only to close a card for a reason the modifier cannot see, such as an archive
/// starting from the keyboard.
@MainActor
@Observable
final class HoverPopoverPresenter {
    static let shared = HoverPopoverPresenter()

    /// The id whose popover is open, or nil. The only observed property, so a hover changes
    /// nothing but the views asking about it.
    private(set) var presented: AnyHashable?

    /// The thing the pointer is on, as far as this knows. Cleared by every dismissal, which is
    /// what makes a dismissal STICK. Without that a card closed by a scroll reopened under a
    /// stationary pointer the moment the scroll ended.
    @ObservationIgnored private var hovered: AnyHashable?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Held for the life of the app, which is the life of this singleton.
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var monitor: Any?

    private init() {
        watchForDismissal()
    }

    func isPresenting(_ id: AnyHashable) -> Bool {
        presented == id
    }

    func pointerEntered(
        _ id: AnyHashable,
        delay: Duration = Motion.hoverCardDelay,
        isEnabled: @escaping @MainActor () -> Bool = { true }
    ) {
        guard hovered != id else { return }
        hovered = id
        pending?.cancel()
        presented = nil

        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.hovered == id else { return }
            // No card over a window that is not the one being worked in. The same fact
            // `didResignKeyNotification` closes on, asked before opening: a window can lose key
            // during the wait.
            guard NSApp.keyWindow?.isVisible == true, isEnabled() else { return }
            self.presented = id
        }
    }

    /// Ignored when the pointer has since arrived somewhere else, because SwiftUI delivers the
    /// arrival on the new view before the departure from the old one.
    func pointerExited(_ id: AnyHashable) {
        guard hovered == id else { return }
        dismiss()
    }

    /// Closes the card and stops anything from opening until the pointer moves again.
    func dismiss() {
        hovered = nil
        pending?.cancel()
        pending = nil
        if presented != nil { presented = nil }
    }

    // MARK: - Everything that closes it

    /// A hover card is a statement about something under the pointer, so anything that makes that
    /// statement stale or makes the card the wrong thing to be looking at closes it.
    ///
    /// Each of these is a case the card would otherwise survive:
    ///
    /// - **A live scroll.** The rows move and the card would go on describing the one that used to
    ///   be there. It also covers a scroll that has not started moving yet, through the wheel
    ///   events below, because `willStartLiveScroll` arrives a frame late.
    /// - **A mouse button going down anywhere.** This is the row being clicked, a row being picked
    ///   up to reorder the pane, and a right click opening the row's own context menu, and all
    ///   three want the card gone before anything else happens. It is a monitor rather than three
    ///   separate observations because a drag has no notification of its own.
    /// - **A menu opening**, which is the same context menu arriving by another route, plus every
    ///   menu bar menu.
    /// - **A sheet arriving**, since a card floating over a modal sheet belongs to a window the
    ///   user can no longer reach.
    /// - **The window losing key, and the app losing active.** A card is a hover state, and a
    ///   hover state that outlives the pointer's window is a card left on screen.
    private nonisolated static func isPopover(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("Popover")
    }

    private func watchForDismissal() {
        let centre = NotificationCenter.default
        for name in [
            NSScrollView.willStartLiveScrollNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.willMiniaturizeNotification,
            NSWindow.willCloseNotification,
            NSMenu.didBeginTrackingNotification,
            NSApplication.didResignActiveNotification,
        ] {
            let observer = centre.addObserver(forName: name, object: nil, queue: .main) { note in
                // Asked before crossing onto the main actor, because the notification itself is
                // not sendable and the two facts read off it are.
                let isOwnWindow = (note.object as? NSWindow).map(Self.isPopover) ?? false
                let resignedKey = note.name == NSWindow.didResignKeyNotification
                MainActor.assumeIsolated {
                    // A popover is a window of its own, and this card's popover opening, taking
                    // key or closing is not a reason to close the card. The old card's window
                    // closing a moment after the next one opened used to close that one too.
                    // AppKit has no public type for a popover's window, so it is told by name.
                    if isOwnWindow { return }
                    if resignedKey, let key = NSApp.keyWindow, Self.isPopover(key) {
                        return
                    }
                    HoverPopoverPresenter.shared.dismiss()
                }
            }
            observers.append(observer)
        }

        // Local, not global: this only has to know about events going to Bloom, and a global
        // monitor is a request for the accessibility permission that Bloom has no other reason to
        // ask for. The event is returned untouched, so nothing here changes what a click does.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { event in
            MainActor.assumeIsolated { HoverPopoverPresenter.shared.dismiss() }
            return event
        }
    }
}

/// The view a hover card's `NSPopover` hangs off. Draws nothing and takes no clicks.
private struct HoverPopoverAnchor<Content: View>: NSViewRepresentable {
    var isPresented: Bool
    var arrowEdge: Edge
    var content: () -> Content
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { PassThroughView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = onClose

        guard isPresented else {
            coordinator.close()
            return
        }
        if let popover = coordinator.popover, popover.isShown {
            (popover.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(content())
            return
        }
        guard view.window != nil else { return }

        let hosting = NSHostingController(rootView: AnyView(content()))
        // The card sizes itself, so the popover asks the hosting controller rather than being told.
        hosting.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = hosting
        popover.delegate = coordinator
        coordinator.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: Self.edge(arrowEdge, in: view))
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    /// SwiftUI's edge names the side the card appears on; AppKit's names the side of the anchor
    /// rectangle, in the anchor view's own coordinates, which are unflipped for a plain `NSView`.
    private static func edge(_ edge: Edge, in view: NSView) -> NSRectEdge {
        let isRightToLeft = view.userInterfaceLayoutDirection == .rightToLeft
        switch edge {
        case .top: return view.isFlipped ? .minY : .maxY
        case .bottom: return view.isFlipped ? .maxY : .minY
        case .leading: return isRightToLeft ? .maxX : .minX
        case .trailing: return isRightToLeft ? .minX : .maxX
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var onClose: () -> Void = {}

        func close() {
            guard let popover else { return }
            self.popover = nil
            popover.delegate = nil
            popover.close()
        }

        /// Closed by something other than the presenter, such as the window going away, so the
        /// presenter hears about it rather than going on believing the card is up.
        nonisolated func popoverDidClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                popover = nil
                onClose()
            }
        }
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

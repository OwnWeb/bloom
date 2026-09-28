import AppKit
import SwiftTerm

#if DEBUG
/// Checks the terminal's scroll bar is the system's, offscreen.
///
/// What is measured is what the owner asked for and what must not break on the way: the style is
/// the one "Show scroll bars" chose; in the overlay style nothing is drawn at rest, which is the
/// whole of "no permanent strip"; showing it does not resize the terminal, because a resize is a
/// reflow and a new width sent to the shell; and scrolling still moves the view and the knob.
/// The fade's timing is not asserted: it is a matter of feel, and a number here would describe the
/// Mac that ran it. Run by `Tools/review-run-probe.sh --terminal-scroller-only`.
@MainActor
enum TerminalScrollerProbe {
    private(set) static var summary = ""

    static func run(check: (Bool, String) -> Void) {
        let preferred = NSScroller.preferredScrollerStyle
        let local = BloomTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let terminals: [(String, SwiftTerm.TerminalView, TerminalScrollerPresenter?)] = [
            ("local", local, local.scrollerPresenter)
        ]
        for (name, terminal, presenter) in terminals {
            // In a window that is never ordered in, so layout happens and nothing is shown.
            let window = NSWindow(contentRect: terminal.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = terminal
            terminal.layoutSubtreeIfNeeded()
            terminal.feed(text: (1...400).map { "line \($0)" }.joined(separator: "\r\n"))

            let scroller = terminal.subviews.compactMap { $0 as? NSScroller }.first
            check(presenter != nil, "the \(name) terminal has no scroller presenter")
            check(scroller != nil, "the \(name) terminal has no scroller")
            guard let presenter, let scroller else { continue }
            check(terminal.scrollerStyle == preferred, "the \(name) terminal's scroller ignores the system's scroll bar setting")
            check(!scroller.isHidden, "the \(name) terminal's scroller was hidden, which resizes the terminal")
            if preferred == .overlay {
                check(scroller.alphaValue == 0, "the \(name) terminal's overlay scroller shows at rest: the permanent strip")
            } else {
                check(scroller.alphaValue == 1, "the \(name) terminal's scroller is hidden although the system says always")
            }

            let columns = terminal.getTerminal().cols
            presenter.flash()
            terminal.layoutSubtreeIfNeeded()
            check(terminal.getTerminal().cols == columns, "showing the \(name) terminal's scroller resized it")
            if preferred == .overlay {
                check(scroller.alphaValue > 0, "the \(name) terminal's scroller did not show when asked")
            }

            check(terminal.canScroll, "the \(name) terminal cannot scroll 400 lines")
            terminal.scroll(toPosition: 0)
            let top = terminal.scrollPosition
            terminal.scroll(toPosition: 1)
            check(top < terminal.scrollPosition, "scrolling the \(name) terminal did not move it")
            check(scroller.isEnabled, "the \(name) terminal's scroller cannot be dragged")
            window.contentView = nil
        }
        summary = "system scroll bars: \(preferred == .overlay ? "when scrolling (overlay)" : "always (legacy)")"
    }
}
#endif

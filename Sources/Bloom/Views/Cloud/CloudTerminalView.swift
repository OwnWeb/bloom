import AppKit
import SwiftTerm

/// SwiftTerm's view, fed bytes from a socket instead of a local process.
///
/// `@preconcurrency` on the delegate, because SwiftTerm's protocol predates isolation and calls it
/// from the view's own key and layout handling, which is the main thread; a call from anywhere else
/// is caught at run time rather than racing.
final class CloudTerminalView: SwiftTerm.TerminalView, @preconcurrency TerminalViewDelegate {
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    /// The system's overlay scroller, faded the way a scroll view fades it. See
    /// `TerminalScrollerPresenter`.
    private(set) var scrollerPresenter: TerminalScrollerPresenter?

    override init(frame: CGRect) {
        super.init(frame: frame, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        terminalDelegate = self
        applyLook()
        scrollerPresenter = TerminalScrollerPresenter(terminal: self)
    }

    /// **The same settings the local terminal draws with**, which is what the owner asked for and
    /// what cost nothing: his scheme, his font, his Ghostty configuration if he follows one. A
    /// Cloud terminal is the same person in the same window doing the same thing, and a second set
    /// of defaults would be a second thing to configure and a second thing to get out of step. See
    /// `TerminalAppearance`.
    func applyLook() {
        let look = TerminalLook.current
        applyBloomFont(
            family: look.fontFamily(for: effectiveAppearance),
            size: look.fontSize(for: effectiveAppearance),
            lineHeight: look.typography.lineHeight
        )
        applyBloomColours()
    }

    /// A `theme = light:…,dark:…` follows the window rather than the app, so the pane is asked
    /// again when the window it is in changes appearance. That is the whole of "it should follow
    /// the window": a light pane in a dark window was never a choice anybody made.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { onInput?(data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { onResize?(newCols, newRows) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    /// Ignored. A program on a shared machine asking to write this Mac's clipboard (OSC 52) is
    /// not something a collaborator's shell, or an agent in it, should be able to do. Copying a
    /// selection with the keyboard is SwiftTerm's own and still works.
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}

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

    override init(frame: CGRect) {
        super.init(frame: frame, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        terminalDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { onInput?(data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { onResize?(newCols, newRows) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}

import Testing
@testable import BloomCore

/// Command+V in a terminal pane, with a screenshot on the clipboard.
///
/// The composer attaches such a clipboard; the terminal could only send its text, of which a
/// screenshot has none, so pasting into a CLI chat did nothing. The pane now hands the CLI the
/// Control+V it reads the clipboard on, and only then.
@Suite("Terminal paste")
struct TerminalPasteTests {
    private func offer(_ formats: PastedImageFormat..., filePath: String? = nil) -> PastedAttachment.Offer {
        PastedAttachment.Offer(filePath: filePath, types: formats.map(\.uti))
    }

    @Test("a screenshot copied rather than saved becomes the CLI's own paste-image key")
    func screenshot() {
        #expect(TerminalPaste.action(items: [offer(.png, .tiff)], hasText: false) == .imageKey)
    }

    @Test("a capture saved to disk still carries the picture the CLI reads")
    func savedCapture() {
        let board = [offer(.png, filePath: "/tmp/shot.png")]
        #expect(TerminalPaste.action(items: board, hasText: false) == .imageKey)
    }

    @Test("text is pasted as text, even beside a picture")
    func textWins() {
        #expect(TerminalPaste.action(items: [offer(.png)], hasText: true) == .text)
    }

    @Test("a file with no picture bytes pastes as the terminal always has, without reading the text")
    func fileStaysText() {
        let board = [offer(filePath: "/tmp/notes.md")]
        var readText = false
        let action = TerminalPaste.action(items: board, hasText: { readText = true; return false }())
        #expect(action == .text)
        #expect(!readText)
    }

    @Test("the key handed over is Control+V in both the legacy and the kitty encoding")
    func keystroke() {
        let key = TerminalPaste.imageKeystroke
        #expect(key.character == "\u{16}")
        #expect(key.unmodifiedCharacter == "v")
        #expect(key.keyCode == 9)
    }
}

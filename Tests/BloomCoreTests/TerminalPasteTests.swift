import Testing
@testable import BloomCore

/// Command+V in a terminal pane, with a screenshot on the clipboard.
///
/// The composer attaches such a clipboard; the terminal could only send its text, of which a
/// screenshot has none, so pasting into a CLI chat did nothing. The pane now hands the CLI the
/// Control+V it reads the clipboard on, and only then.
@Suite("Terminal paste")
struct TerminalPasteTests {
    @Test("a screenshot copied rather than saved becomes the CLI's own paste-image key")
    func screenshot() {
        let board = [PastedAttachment.Offer(types: ["public.png", "public.tiff"])]
        #expect(TerminalPaste.action(items: board, hasText: false) == .imageKey)
    }

    @Test("a capture saved to disk still carries the picture the CLI reads")
    func savedCapture() {
        let board = [PastedAttachment.Offer(filePath: "/tmp/shot.png", types: ["public.file-url", "public.png"])]
        #expect(TerminalPaste.action(items: board, hasText: false) == .imageKey)
    }

    @Test("text is pasted as text, even beside a picture")
    func textWins() {
        let board = [PastedAttachment.Offer(types: ["public.utf8-plain-text", "public.png"])]
        #expect(TerminalPaste.action(items: board, hasText: true) == .text)
    }

    @Test("a file with no picture bytes pastes as the terminal always has, without reading the text")
    func fileStaysText() {
        let board = [PastedAttachment.Offer(filePath: "/tmp/notes.md", types: ["public.file-url"])]
        var readText = false
        let action = TerminalPaste.action(items: board, hasText: { readText = true; return false }())
        #expect(action == .text)
        #expect(!readText)
    }
}

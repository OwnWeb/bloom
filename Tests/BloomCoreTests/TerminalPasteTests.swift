import Testing
@testable import BloomCore

/// Command+V in a terminal pane, with a screenshot on the clipboard.
///
/// The composer attaches such a clipboard; the terminal could only send its text, of which a
/// screenshot has none, so pasting into a CLI chat did nothing. The pane now hands the CLI the
/// Control+V it reads the clipboard on, and only then.
@Suite("Terminal paste")
struct TerminalPasteTests {
    private func image(_ formats: PastedImageFormat...) -> PastedAttachment.Offer {
        PastedAttachment.Offer(types: formats.map(\.uti))
    }

    @Test("a screenshot copied rather than saved becomes the CLI's own paste-image key")
    func screenshot() {
        let plan = PastedAttachment.plan(items: [image(.png, .tiff)], hasText: false)
        #expect(TerminalPaste.action(for: plan) == .imageKey)
    }

    @Test("text is pasted as text, even beside a picture")
    func textWins() {
        let plan = PastedAttachment.plan(items: [image(.png)], hasText: true)
        #expect(TerminalPaste.action(for: plan) == .text)
    }

    @Test("a file copied in Finder pastes as the terminal always has")
    func fileStaysText() {
        let file = PastedAttachment.Offer(filePath: "/tmp/shot.png", types: ["public.file-url", "public.png"])
        let plan = PastedAttachment.plan(items: [file], hasText: false)
        #expect(TerminalPaste.action(for: plan) == .text)
    }
}

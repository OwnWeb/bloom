import Testing
@testable import BloomCore

@Suite("Sent turn preview")
struct SentTurnPreviewTests {
    @Test("a message that fits is drawn whole")
    func shortIsWhole() {
        #expect(SentTurnPreview.cut("Peux-tu regarder ?\n\nMerci") == nil)
        #expect(SentTurnPreview.cut("") == nil)
    }

    @Test("a message at both limits exactly is drawn whole")
    func atLimitsIsWhole() {
        let lines = Array(repeating: "x", count: SentTurnPreview.maxLines).joined(separator: "\n")
        #expect(SentTurnPreview.cut(lines) == nil)
        #expect(SentTurnPreview.cut(String(repeating: "a", count: SentTurnPreview.maxCharacters)) == nil)
    }

    @Test("a pasted log keeps its first lines")
    func longLogKeepsFirstLines() {
        let lines = (1...200).map { "line \($0)" }
        let cut = SentTurnPreview.cut(lines.joined(separator: "\n"))
        let expected = lines.prefix(SentTurnPreview.maxLines).joined(separator: "\n") + SentTurnPreview.ellipsis
        #expect(cut == expected)
    }

    @Test("a base64 image on one line keeps its first characters")
    func oneLongLineKeepsFirstCharacters() {
        let blob = String(repeating: "QUJD", count: 60_000)
        let cut = SentTurnPreview.cut("data:image/png;base64," + blob)
        #expect(cut?.count == SentTurnPreview.maxCharacters + SentTurnPreview.ellipsis.count)
        #expect(cut?.hasPrefix("data:image/png;base64,QUJD") == true)
    }

    @Test("Windows line endings count as lines")
    func carriageReturnsCount() {
        let lines = (1...100).map { "row \($0)" }
        let cut = SentTurnPreview.cut(lines.joined(separator: "\r\n"))
        #expect(cut == lines.prefix(SentTurnPreview.maxLines).joined(separator: "\r\n") + SentTurnPreview.ellipsis)
    }

    @Test("a final line break is not a line of its own")
    func trailingNewlineIsWhole() {
        let lines = Array(repeating: "x", count: SentTurnPreview.maxLines).joined(separator: "\n")
        #expect(SentTurnPreview.cut(lines + "\n") == nil)
    }

    @Test("a merge turn keeps its instructions whole, so they are still drawn as a chip")
    func mergeTurnIsWhole() {
        let turn = "Merge #42.\n\n\(MergeInstructions.canonical)"
        #expect(turn.count > SentTurnPreview.maxCharacters)
        #expect(SentTurnPreview.cut(turn) == nil)
    }

    @Test("a paste before Bloom's instructions is cut, and the instructions go with the rest")
    func pasteBeforeInstructionsIsCut() {
        let paste = String(repeating: "QUJD", count: 5_000)
        let cut = SentTurnPreview.cut(paste + "\n\n" + MergeInstructions.canonical)
        #expect(cut == String(paste.prefix(SentTurnPreview.maxCharacters)) + SentTurnPreview.ellipsis)
    }
}

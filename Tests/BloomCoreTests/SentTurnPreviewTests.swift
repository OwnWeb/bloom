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
}

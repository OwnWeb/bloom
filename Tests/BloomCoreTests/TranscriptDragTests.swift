import Testing
@testable import BloomCore

@Suite("Transcript drag")
struct TranscriptDragTests {
    @Test("a press on a link that shifts by a point is still a click")
    func jitterIsAClick() {
        #expect(!TranscriptDrag.text.leavesClick(dx: 1, dy: -1))
    }

    @Test("a press on text that moves past its slop is a drag, measured along the diagonal")
    func diagonalIsADrag() {
        #expect(TranscriptDrag.text.leavesClick(dx: 3, dy: 3))
    }

    @Test("a press elsewhere in a row keeps a button's click through a wider tremble")
    func rowToleratesMore() {
        #expect(!TranscriptDrag.row.leavesClick(dx: 6, dy: 0))
        #expect(TranscriptDrag.row.leavesClick(dx: 13, dy: 0))
    }
}

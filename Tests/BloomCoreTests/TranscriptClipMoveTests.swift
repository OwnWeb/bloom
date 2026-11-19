import Foundation
import Testing
@testable import BloomCore

@Suite("A transcript's clip view moving")
struct TranscriptClipMoveTests {
    @Test("a move nobody was writing is unexplained once it is past the slack")
    func unclaimedMoves() {
        #expect(TranscriptClipMove.isUnexplained(from: 4_000, to: 400, writers: []))
        #expect(TranscriptClipMove.isUnexplained(from: 400, to: 4_000, writers: []))
        #expect(!TranscriptClipMove.isUnexplained(from: 4_000, to: 3_994, writers: []))
    }

    @Test("any known writer explains a move, however far")
    func claimedMoves() {
        let writers: [TranscriptClipMove.Writers] = [
            .table, .follower, .documentResize, .viewportResize, .reader, [.table, .documentResize]
        ]
        for writer in writers {
            #expect(!TranscriptClipMove.isUnexplained(from: 30_000, to: 0, writers: writer))
        }
    }

    @Test("the writers are named in the log line, and nobody is said as such")
    func writersAreNamed() {
        #expect(TranscriptClipMove.Writers().description == "nobody")
        #expect(TranscriptClipMove.Writers([.documentResize, .table]).description == "table+document")
    }

    @Test("only the keys that scroll are told apart from the rest")
    func scrollKeys() {
        let pageUp: UInt16 = 116
        let letterA: UInt16 = 0
        #expect(TranscriptClipMove.isScrollKey(pageUp))
        #expect(!TranscriptClipMove.isScrollKey(letterA))
    }

    @Test("one line a window, and the next one counts what was kept back")
    func budget() {
        var budget = TranscriptClipMove.Budget()
        let first = budget.spend(at: 10)
        let second = budget.spend(at: 10.2)
        let third = budget.spend(at: 10.9)
        let afterTheWindow = budget.spend(at: 11.1)
        let afterAQuietWindow = budget.spend(at: 13)
        #expect(first == 0)
        #expect(second == nil)
        #expect(third == nil)
        #expect(afterTheWindow == 2)
        #expect(afterAQuietWindow == 0)
    }
}

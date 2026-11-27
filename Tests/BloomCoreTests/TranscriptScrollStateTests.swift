import Foundation
import Testing
@testable import BloomCore

/// Each jump logged between 16 and 18 November replayed as events, with the hostile inputs the log
/// showed: a stale replay written by the table, a pane with no height, a document collapsing, and
/// AppKit clamping the origin. Each test goes red if the state took a place from any of them.
@Suite("A transcript pane's place, held as state")
struct TranscriptScrollStateTests {
    private static let viewport: Double = 800
    private static let rowHeight: Double = 400

    private typealias State = TranscriptScrollState
    private typealias Frame = TranscriptScrollState.RowFrame

    /// Rows of one height stacked from the top, which is enough to say where a row is.
    private static func stacked(
        rows: Int, content: Double? = nil, viewport: Double = viewport
    ) -> State.Geometry {
        let height = Double(rows) * rowHeight
        return State.Geometry(contentHeight: content ?? height, viewportHeight: viewport) { id in
            guard let seq = id.seq, seq < rows else { return nil }
            return Frame(top: Double(seq) * rowHeight, height: rowHeight)
        }
    }

    private static func end(of geometry: State.Geometry) -> Double {
        geometry.contentHeight - geometry.viewportHeight
    }

    @Test("Berlingo, 17/11 10:14: the first opening's re-aim lands after the end was asked for")
    func reaimAfterTheEnd() {
        let unreadRow: TranscriptEntryID = .row(48)
        var state = State()
        state.apply(.navigated(.row(unreadRow, delta: 0)))
        state.apply(.navigated(.end))
        // The re-aim writes the unread row a turn later, once the rows have been measured taller.
        let measured = Self.stacked(rows: 60, content: 24_800)
        state.apply(.clipMoved(to: .row(unreadRow, delta: 0), by: .table))
        #expect(state.place == .end)
        #expect(state.origin(in: measured) == Self.end(of: measured))
    }

    @Test("17/11 19:37: put at the end before the pane had a height, then thrown to the top")
    func endBeforeThePaneHasAHeight() {
        var state = State()
        state.apply(.navigated(.end))
        let unlaid = Self.stacked(rows: 112, viewport: 0)
        #expect(state.origin(in: unlaid) == nil)
        #expect(State.read(offset: 0, topRow: .row(0), in: unlaid) == nil)

        let laidOut = Self.stacked(rows: 112)
        #expect(state.origin(in: laidOut) == Self.end(of: laidOut))
        // The reflow read the top row from a pane just laid out, and the place work replayed it.
        state.apply(.clipMoved(to: .row(.row(0), delta: 0), by: .viewportResize))
        state.apply(.clipMoved(to: .row(.row(0), delta: 0), by: .table))
        let rewidthed = Self.stacked(rows: 30)
        #expect(state.place == .end)
        #expect(state.origin(in: rewidthed) == Self.end(of: rewidthed))
    }

    @Test("17/11 20:46, side conversation: revealed at the end, re-aimed at unread row 13")
    func reaimOfTheFirstOpening() {
        let unreadRow: TranscriptEntryID = .row(13)
        var state = State()
        state.apply(.navigated(.row(unreadRow, delta: 0)))
        state.apply(.navigated(.end))
        state.apply(.clipMoved(to: .row(unreadRow, delta: 0), by: .table))
        let geometry = Self.stacked(rows: 40)
        #expect(state.place == .end)
        #expect(state.origin(in: geometry) == Self.end(of: geometry))
    }

    @Test("18/11 07:42: re-aimed at row 1 while the document fell from 45,234 to 3,499 points")
    func documentCollapsingUnderTheEnd() {
        var state = State()
        state.apply(.navigated(.row(.row(1), delta: 0)))
        state.apply(.navigated(.end))
        state.apply(.clipMoved(to: .row(.row(1), delta: 0), by: .table))
        let announcedHeights: [Double] = [45_234, 28_899, 3_499]
        for content in announcedHeights {
            // AppKit clamps the origin as the document shrinks, and that is no reader.
            state.apply(.clipMoved(to: .row(.row(1), delta: 0), by: .documentResize))
            let geometry = Self.stacked(rows: 9, content: content)
            #expect(state.place == .end)
            #expect(state.origin(in: geometry) == Self.end(of: geometry))
        }
    }

    @Test("family B: a link view nudging every pane at the end of a live resize moves no place")
    func unattributedNudge() throws {
        let nudge: Double = 14
        var state = State()
        let geometry = Self.stacked(rows: 50)
        let nudged = try #require(
            State.read(offset: Self.end(of: geometry) - nudge, topRow: .row(47), in: geometry)
        )
        #expect(nudged != .end)
        for writers: TranscriptClipMove.Writers in [[], .viewportResize, [.reader, .viewportResize]] {
            state.apply(.clipMoved(to: nudged, by: writers))
        }
        #expect(state.place == .end)
        #expect(state.origin(in: geometry) == Self.end(of: geometry))
    }

    @Test("a reader who scrolls up keeps their row while rows arrive below and are measured above")
    func readerKeepsTheirRow() throws {
        let readerSeq = 10
        let readerRow: TranscriptEntryID = .row(readerSeq)
        let intoRow: Double = 120
        var state = State()
        let geometry = Self.stacked(rows: 50)
        let rowTop = Double(readerSeq) * Self.rowHeight
        let read = try #require(State.read(offset: rowTop + intoRow, topRow: readerRow, in: geometry))
        state.apply(.clipMoved(to: read, by: .reader))
        #expect(state.origin(in: geometry) == rowTop + intoRow)

        let grownBelow = Self.stacked(rows: 80)
        #expect(state.origin(in: grownBelow) == rowTop + intoRow)

        let measuredTaller: Double = 600
        let content = grownBelow.contentHeight + measuredTaller
        let grownAbove = State.Geometry(contentHeight: content, viewportHeight: Self.viewport) { id in
            id == readerRow ? Frame(top: rowTop + measuredTaller, height: Self.rowHeight) : nil
        }
        #expect(state.origin(in: grownAbove) == rowTop + measuredTaller + intoRow)
    }

    @Test("a reader who comes back to the end follows it again")
    func readerReturnsToTheEnd() throws {
        var state = State(place: .row(.row(10), delta: -120))
        let geometry = Self.stacked(rows: 50)
        let read = try #require(State.read(offset: Self.end(of: geometry), topRow: .row(48), in: geometry))
        state.apply(.clipMoved(to: read, by: .reader))
        let grown = Self.stacked(rows: 70)
        #expect(state.place == .end)
        #expect(state.origin(in: grown) == Self.end(of: grown))
    }

    @Test("an aimed row is resolved again when it is measured, as the unfolded setup log is")
    func aimedRowFollowsItsHeight() {
        let folded: Double = 80
        let unfolded: Double = 20_000
        let below: Double = 1_000
        func setup(height: Double) -> State.Geometry {
            State.Geometry(contentHeight: height + below, viewportHeight: Self.viewport) { id in
                id == .setup ? Frame(top: 0, height: height) : nil
            }
        }
        var state = State()
        state.apply(.navigated(.aimed(.setup, anchor: 1)))
        #expect(state.origin(in: setup(height: folded)) == 0)
        #expect(state.origin(in: setup(height: unfolded)) == unfolded - Self.viewport)
    }

    @Test("a row that is not in the table writes nothing and is not forgotten")
    func missingRow() {
        let place: State.Place = .row(.row(90), delta: -40)
        let state = State(place: place)
        #expect(state.origin(in: Self.stacked(rows: 50)) == nil)
        #expect(state.place == place)
    }

    @Test("a reading within a point of the end is the end, and a reading with no row is none")
    func readings() {
        let geometry = Self.stacked(rows: 50)
        let withinRounding: Double = 0.5
        let atEnd = State.read(offset: Self.end(of: geometry) - withinRounding, topRow: .row(48), in: geometry)
        let noRow = State.read(offset: 0, topRow: nil, in: geometry)
        #expect(atEnd == .end)
        #expect(noRow == nil)
    }
}

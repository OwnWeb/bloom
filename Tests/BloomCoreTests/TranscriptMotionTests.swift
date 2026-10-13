import Testing
import Foundation
@testable import BloomCore

@Suite("What the transcript animates")
struct TranscriptMotionTests {
    @Test("a row that lands where something else was fades in")
    func rowsThatFade() {
        #expect(TranscriptMotion.fadesOnArrival(.toolUse))
        #expect(TranscriptMotion.fadesOnArrival(.toolResult))
        #expect(TranscriptMotion.fadesOnArrival(.permissionAsk))
        #expect(TranscriptMotion.fadesOnArrival(.result))
        #expect(TranscriptMotion.fadesOnArrival(.error))
        #expect(TranscriptMotion.fadesOnArrival(.system))
        #expect(TranscriptMotion.fadesOnArrival(.notice))
    }

    /// All three are already on screen when the stored row lands, drawn by something lined up
    /// column for column with it. A fade would take what the reader is looking at away and bring
    /// it back.
    @Test("a row that replaces something already drawn does not")
    func rowsThatDoNotFade() {
        #expect(!TranscriptMotion.fadesOnArrival(.assistantText))
        #expect(!TranscriptMotion.fadesOnArrival(.thinking))
        #expect(!TranscriptMotion.fadesOnArrival(.user))
    }

    // MARK: - Settling onto the screen

    /// Shape rather than literals: what matters is that there is travel under the opacity and
    /// that the whole thing is over quickly. Opacity alone was filmed and measured at a thirtieth
    /// the weight of an ordinary stream delta landing beside it, which is why a rise of zero is
    /// the one value this must never come back to.
    @Test("a settle has both a length and some travel, and neither is an effect")
    func settleShape() throws {
        let settle = try #require(TranscriptMotion.arrival(reduceMotion: false))
        #expect(settle.rise > 0)
        #expect(settle.rise < 12)
        #expect(settle.seconds > 0.1)
        #expect(settle.seconds < 0.4)
    }

    /// Dropped rather than slowed, like every other call site in the app, and absent rather than
    /// zeroed so that a caller cannot honour half of it and leave a row hidden.
    @Test("Reduce Motion is owed no settle at all")
    func settleUnderReduceMotion() {
        #expect(TranscriptMotion.arrival(reduceMotion: true) == nil)
    }

    /// The three that do not fade each earned it with a measurement; everything else fades because
    /// it genuinely turns up. That used to be a `default`, so a kind added to `MessageKind` was
    /// given the fade without anybody deciding, which is how `.crew` got its answer. The switch is
    /// written out on both sides now and this pins the split, over `allCases` rather than over a
    /// handful of kinds, so a new one has to be argued for here as well as compiled.
    @Test("exactly the three rows that are already on screen refuse to fade")
    func onlyTheEchoedKindsRefuseTheFade() {
        let still = MessageKind.allCases.filter { !TranscriptMotion.fadesOnArrival($0) }
        #expect(Set(still) == [.assistantText, .thinking, .user])
        #expect(still.count + MessageKind.allCases.count(where: TranscriptMotion.fadesOnArrival)
            == MessageKind.allCases.count)
    }
}

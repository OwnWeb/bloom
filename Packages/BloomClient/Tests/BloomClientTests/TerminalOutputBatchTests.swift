import Foundation
import Testing
@testable import BloomClient

@Suite("A Cloud terminal's output, fed once per refresh")
struct TerminalOutputBatchTests {
    /// The measured burst: `seq 1 5000` through tmux's control mode is 849 frames. Fed as they
    /// came it was 849 feeds; here it is one per refresh the burst spans.
    @Test("a burst between two refreshes is one feed, in the order it arrived")
    func burstIsOneFeed() {
        var batch = TerminalOutputBatch()
        var feeds = 0
        var fed = Data()
        var expected = Data()
        var arrivals: [TerminalOutputBatch.Arrival] = []
        for index in 0..<849 {
            let frame = Data("\(index + 1)\r\n".utf8)
            expected.append(frame)
            arrivals.append(batch.append(frame))
        }
        let taken = batch.take()
        feeds += 1
        fed.append(taken.bytes)

        #expect(arrivals.first == .schedule)
        #expect(arrivals.dropFirst().allSatisfy { $0 == .wait })
        #expect(taken.frames == 849)
        #expect(feeds == 1)
        #expect(fed == expected)
        #expect(batch.isEmpty)
    }

    @Test("the next frame after a feed asks for the next refresh")
    func nextBurstSchedules() {
        var batch = TerminalOutputBatch()
        _ = batch.append(Data("a".utf8))
        _ = batch.take()
        let next = batch.append(Data("b".utf8))
        let empty = batch.append(Data())
        let taken = batch.take()
        #expect(next == .schedule)
        #expect(empty == .wait)
        #expect(taken.frames == 1)
    }

    /// A hidden window gets no refresh, so a flood must not wait for one.
    @Test("past the limit it feeds at once")
    func bounded() {
        var batch = TerminalOutputBatch()
        let first = batch.append(Data(count: TerminalOutputBatch.limit - 1))
        let full = batch.append(Data(count: 1))
        #expect(first == .schedule)
        #expect(full == .feedNow)
    }
}

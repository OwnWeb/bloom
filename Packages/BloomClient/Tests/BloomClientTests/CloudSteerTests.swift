import Testing
@testable import BloomClient

@Suite("Steering a turn on a machine")
struct CloudSteerTests {
    @Test("Your own message, your own turn, nothing else waiting")
    func theOneCaseItIsOffered() {
        #expect(CloudSteer.canSteer(
            isRunning: true, promptIsReaders: true, runningTurnIsReaders: true, queued: 1
        ))
    }

    @Test("Never for somebody else's words, or over somebody else's turn")
    func notForSomebodyElse() {
        #expect(!CloudSteer.canSteer(
            isRunning: true, promptIsReaders: false, runningTurnIsReaders: true, queued: 1
        ))
        #expect(!CloudSteer.canSteer(
            isRunning: true, promptIsReaders: true, runningTurnIsReaders: false, queued: 1
        ))
    }

    /// The one that is about the machine rather than about manners: with anything else queued, the
    /// machine starts that next and this message goes to the back of the queue it was already in,
    /// so the turn would have been stopped for nothing.
    @Test("Never with anything else in the queue")
    func notWithAQueueBehindIt() {
        #expect(!CloudSteer.canSteer(
            isRunning: true, promptIsReaders: true, runningTurnIsReaders: true, queued: 2
        ))
    }

    @Test("And never with no turn to replace")
    func notWithNothingRunning() {
        #expect(!CloudSteer.canSteer(
            isRunning: false, promptIsReaders: true, runningTurnIsReaders: true, queued: 1
        ))
    }
}

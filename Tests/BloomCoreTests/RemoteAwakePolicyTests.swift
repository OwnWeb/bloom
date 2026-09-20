import Foundation
import Testing
@testable import BloomCore

@Suite("Cloud workspace awake policy")
struct RemoteAwakePolicyTests {
    let now = Date(timeIntervalSince1970: 1_789_638_000)

    func minutes(_ value: Double) -> TimeInterval { value * 60 }

    @Test("an idle machine with nobody working may sleep, however many windows are open")
    func openStreamsAreNotAReason() {
        let decision = RemoteAwakePolicy.decide(.init(openStreams: 3), now: now)
        #expect(!decision.holds)
    }

    @Test("setup, a turn and a run script each hold the machine")
    func workHolds() {
        #expect(RemoteAwakePolicy.decide(.init(setupRunning: true), now: now).reasons == [.setup])
        #expect(RemoteAwakePolicy.decide(.init(turnsRunning: 1), now: now).reasons == [.turn])
        #expect(RemoteAwakePolicy.decide(.init(scriptsRunning: 2), now: now).reasons == [.script])
    }

    @Test("human input holds the machine for fifteen minutes")
    func presenceLease() {
        let input = now.addingTimeInterval(-minutes(14))
        let holding = RemoteAwakePolicy.decide(.init(lastHumanInputAt: input, openStreams: 1), now: now)
        #expect(holding.reasons == [.humanInput])
        #expect(holding.reconsiderAt == input.addingTimeInterval(minutes(15)))
        let expired = RemoteAwakePolicy.decide(.init(lastHumanInputAt: now.addingTimeInterval(-minutes(16)), openStreams: 1), now: now)
        #expect(!expired.holds)
    }

    @Test("the lease ends two minutes after the last stream closes, unless somebody did something since")
    func closingTheLastStreamShortensTheLease() {
        let input = now.addingTimeInterval(-minutes(5))
        let closed = now.addingTimeInterval(-minutes(3))
        #expect(!RemoteAwakePolicy.decide(.init(lastHumanInputAt: input, openStreams: 0, lastStreamClosedAt: closed), now: now).holds)

        let recentlyClosed = now.addingTimeInterval(-minutes(1))
        let stillHolding = RemoteAwakePolicy.decide(.init(lastHumanInputAt: input, openStreams: 0, lastStreamClosedAt: recentlyClosed), now: now)
        #expect(stillHolding.reasons == [.humanInput])
        #expect(stillHolding.leaseUntil == recentlyClosed.addingTimeInterval(minutes(2)))

        let typedAfterClosing = RemoteAwakePolicy.decide(.init(lastHumanInputAt: now.addingTimeInterval(-minutes(1)), openStreams: 0,
                                                               lastStreamClosedAt: closed), now: now)
        #expect(typedAfterClosing.holds)
    }

    @Test("a turn waiting on a question holds for the length of the lease after it was asked, and no longer")
    func questionsDoNotHoldForever() {
        let asked = now.addingTimeInterval(-minutes(10))
        let waiting = RemoteAwakePolicy.decide(.init(turnsRunning: 1, questionWaitingSince: asked), now: now)
        #expect(waiting.reasons == [.turn])
        #expect(waiting.reconsiderAt == asked.addingTimeInterval(minutes(15)))
        let abandoned = RemoteAwakePolicy.decide(.init(turnsRunning: 1, questionWaitingSince: now.addingTimeInterval(-minutes(20))), now: now)
        #expect(!abandoned.holds)
    }
}

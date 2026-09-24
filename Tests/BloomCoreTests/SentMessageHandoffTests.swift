import Foundation
import Testing
@testable import BloomCore

@Suite("Cloud sent-message handoff")
struct SentMessageHandoffTests {
    private func row(_ text: String, author: String) -> Message {
        let payload = Data("""
            {"message":{"content":[{"text":"\(text)"}]}}
            """.utf8)
        return Message(
            sessionID: SessionID("chat"), seq: 1, kind: .user, payload: payload,
            author: MessageAuthor(userID: author, name: author)
        )
    }

    @Test func savedRowResumesTheEchoAfterTheQueueAcknowledgement() {
        let start = Date(timeIntervalSince1970: 1000)
        let delivery = Delivery(id: DeliveryID("local"), targetSessionID: SessionID("chat"), body: "Hello")
        var arrivals = MessageArrivals()
        arrivals.sent(delivery.id, at: start)
        var handoff = SentMessageHandoff()
        handoff.hold(delivery)

        let id = handoff.take(for: row("Hello", author: "me"), readerID: "me")
        #expect(id == delivery.id)
        arrivals.persisted(seq: 1, kind: .user, sending: id, at: start.addingTimeInterval(0.2))
        #expect(arrivals.row(1)?.startedAt == start)
        let repeated = handoff.take(for: row("Hello", author: "me"), readerID: "me")
        #expect(repeated == nil)
    }

    @Test func anotherPersonsRowCannotConsumeTheEcho() {
        let delivery = Delivery(id: DeliveryID("local"), targetSessionID: SessionID("chat"), body: "Hello")
        var handoff = SentMessageHandoff()
        handoff.hold(delivery)

        let otherAuthor = handoff.take(for: row("Hello", author: "teammate"), readerID: "me")
        let otherText = handoff.take(for: row("Different", author: "me"), readerID: "me")
        let own = handoff.take(for: row("Hello", author: "me"), readerID: "me")
        #expect(otherAuthor == nil)
        #expect(otherText == nil)
        #expect(own == delivery.id)
    }
}

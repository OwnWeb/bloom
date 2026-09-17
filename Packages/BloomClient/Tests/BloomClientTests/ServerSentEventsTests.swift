@testable import BloomClient
import BloomProtocol
import Foundation
import Testing

@Suite struct ServerSentEventsTests {
    private func events(_ lines: [String]) -> [ServerSentEvents.Event] {
        var parser = ServerSentEvents()
        return lines.compactMap { parser.feed($0) }
    }

    @Test func readsKindIdAndData() {
        let read = events(["event: message", "id: 1843", #"data: {"kind":"message"}"#, ""])
        #expect(read == [.init(name: "message", id: "1843", data: #"{"kind":"message"}"#)])
    }

    @Test func keepAlivesAndEmptyEventsAreNothing() {
        #expect(events([": keep-alive", "", "", "event: sleeping", ""]).isEmpty)
    }

    @Test func dataOnSeveralLinesIsJoined() {
        #expect(events(["data: a", "data:b", ""]).map(\.data) == ["a\nb"])
    }

    @Test func anEventWithoutANameIsAMessage() {
        #expect(events(["data: x", ""]).map(\.name) == ["message"])
    }
}

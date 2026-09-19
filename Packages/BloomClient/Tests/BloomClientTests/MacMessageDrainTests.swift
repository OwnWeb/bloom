import BloomProtocol
import Foundation
import Testing
@testable import BloomClient

/// Messages runbloom.app held for this Mac: read as the control server documented them, and
/// acknowledged only once they have landed.
@Suite("Messages runbloom.app holds for this Mac")
struct MacMessageDrainTests {
    private static let page = """
        {"messages": [{"id": "m1", "team": {"id": "t1", "name": "Spatie"}, "from_workspace": {"id": "cw1", "name": "Payments"}, \
        "via": {"chat": "Chat"}, "target_workspace": "Queue retries", "text": "Rebase on main.", \
        "created_at": "2026-09-19T12:00:00Z", "expires_at": "2026-09-26T12:00:00Z"}]}
        """

    @Test("the list is read as documented, bare or enveloped, and becomes the live stream's record")
    func reads() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/me/mac-messages", .json(Self.page))
        let messages = try await Fixtures.api(transport).macMessages()
        // The whole address, not just its tail: a drain that asks the wrong path gets a 404 that
        // looks exactly like a server without the route, which is a day to tell apart by hand.
        #expect(transport.requests.map { $0.url?.absoluteString } == ["https://runbloom.test/api/v1/me/mac-messages"])
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        let message = try #require(messages.first)
        #expect(message.team?.name == "Spatie")
        #expect(message.fromWorkspace.name == "Payments")
        #expect(message.targetWorkspace == "Queue retries")
        #expect(message.record(for: "u-freek") == MacMessageRecord(
            id: "m1", userID: "u-freek", workspace: "Queue retries", text: "Rebase on main.",
            via: ViaRecord(workspace: "Payments", chat: "Chat")
        ))

        let wrapped = FakeTransport()
        wrapped.on("GET", "/me/mac-messages", .json(#"{"data": \#(Self.page)}"#))
        #expect(try await Fixtures.api(wrapped).macMessages().map(\.id) == ["m1"])
    }

    @Test("acknowledging is a DELETE on the message, and a 404 on a repeat is already done")
    func acknowledges() async throws {
        let transport = FakeTransport()
        transport.on("DELETE", "/me/mac-messages/m1", .noContent())
        try await Fixtures.api(transport).acknowledgeMacMessage("m1")
        #expect(transport.requests(to: "/me/mac-messages/m1").map(\.httpMethod) == ["DELETE"])

        // A repeat answers 404, which is the same as done.
        let again = FakeTransport()
        again.on("DELETE", "/me/mac-messages/m1", .json(#"{"message":"Not found."}"#, status: 404))
        try await Fixtures.api(again).acknowledgeMacMessage("m1")
    }

    private func message(_ id: String) -> DepositedMacMessage {
        DepositedMacMessage(id: id, fromWorkspace: .init(id: "cw1", name: "Payments"), targetWorkspace: "Here", text: "Hi")
    }

    /// A crash halfway through loses nothing: what was not acknowledged is offered again.
    @Test("only what settled is acknowledged, in order, and a failed acknowledgement is not counted")
    func acknowledgesSettled() async {
        let log = Log()
        let acknowledged = await MacMessageDrain().drain(
            list: { [self] in [message("a"), message("b"), message("c"), message("d")] },
            land: { $0.id == "b" ? .later : .settled },
            acknowledge: { id in
                if id == "d" { throw URLError(.networkConnectionLost) }
                log.add(id)
            }
        )
        #expect(acknowledged == ["a", "c"])
        #expect(log.values == ["a", "c"])
    }

    @Test("a list that cannot be read, such as a server without the route yet, lands nothing")
    func listFails() async {
        let acknowledged = await MacMessageDrain().drain(
            list: { throw RunbloomRefusal(status: 404, code: "not_found", message: "") },
            land: { _ in Issue.record("nothing to land"); return .settled },
            acknowledge: { _ in }
        )
        #expect(acknowledged == [])
    }

    @Test("a second drain while one runs is skipped rather than landing the same messages twice")
    func oneAtATime() async {
        let drain = MacMessageDrain()
        let (entered, enteredGate) = AsyncStream<Void>.makeStream()
        let (release, releaseGate) = AsyncStream<Void>.makeStream()
        let first = Task {
            await drain.drain(
                list: {
                    enteredGate.yield()
                    for await _ in release { break }
                    return []
                },
                land: { _ in .settled }, acknowledge: { _ in }
            )
        }
        for await _ in entered { break }
        let second = await drain.drain(list: { [] }, land: { _ in .settled }, acknowledge: { _ in })
        #expect(second == nil)
        releaseGate.yield()
        #expect(await first.value == [])
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var values: [String] { lock.withLock { ids } }
    }
}

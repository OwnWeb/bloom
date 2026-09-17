@testable import BloomClient
import BloomProtocol
import Foundation
import Testing

@Suite struct WorkspaceConnectionTests {
    private func connection(_ transport: FakeTransport) -> WorkspaceConnection {
        WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(transport), machine: MachineClient(transport: transport),
            sleep: { _ in await Task.yield() }
        )
    }

    private func reply(_ commandID: String, _ result: OperationResult) -> String {
        Records.json(CommandReply(commandID: commandID, result: result))
    }

    @Test func aCommandWithNoAnswerIsRetriedUnderTheSameCommandID() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("POST", "/_bloom/v1/rpc", .dropped(), .json(reply("cmd-1", .queued(promptID: "p1"))))
        let result = try await connection(transport).perform(.send(chatID: "c1", text: "Run the tests"), commandID: "cmd-1")
        #expect(result == .queued(promptID: "p1"))
        let sent = transport.requests(to: "/_bloom/v1/rpc").compactMap(\.httpBody).map { try? WireJSON.decode(CommandRequest.self, from: $0) }
        #expect(sent.count == 2)
        #expect(sent.map { $0?.commandID } == ["cmd-1", "cmd-1"])
    }

    @Test func aRefusedTokenIsReplacedOnce() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken("old")), .json(Fixtures.sessionToken("new")))
        transport.on("POST", "/_bloom/v1/rpc",
                     .json(#"{"code": "token_expired", "message": "Expired."}"#, status: 401),
                     .json(reply("cmd-2", .accepted)))
        let result = try await connection(transport).perform(.stop(chatID: "c1"), commandID: "cmd-2")
        #expect(result == .accepted)
        let tokens = transport.requests(to: "/_bloom/v1/rpc").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(tokens == ["Bearer old", "Bearer new"])
    }

    @Test func aRefusalFromTheMachineIsNotRetried() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("POST", "/_bloom/v1/rpc", .json(Records.json(CommandReply(commandID: "cmd-3", error: WireError(.alreadyAnswered, "Answered by Alex.")))))
        do {
            _ = try await connection(transport).perform(.answer(chatID: "c1", requestID: "r", answer: .allowOnce), commandID: "cmd-3")
            Issue.record("Expected a refusal")
        } catch {
            #expect(error.code == .alreadyAnswered)
            #expect(error.message == "Answered by Alex.")
        }
        #expect(transport.requests(to: "/_bloom/v1/rpc").count == 1)
    }

    @Test func theFirstRequestToASleepingMachineIsGivenTimeToWake() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken(awake: false)))
        transport.on("POST", "/_bloom/v1/rpc", .json(reply("a", .accepted)), .json(reply("b", .accepted)))
        let connection = connection(transport)
        _ = try await connection.perform(.markRead(chatID: "c1", seq: 1), commandID: "a")
        _ = try await connection.perform(.markRead(chatID: "c1", seq: 2), commandID: "b")
        let timeouts = transport.requests(to: "/_bloom/v1/rpc").map(\.timeoutInterval)
        #expect(timeouts[0] >= 10)
        #expect(timeouts[1] < timeouts[0])
    }

    @Test func aTokenNearItsExpiryIsReplacedBeforeItIsUsed() async throws {
        let transport = FakeTransport()
        let soon = RunbloomDate.format(Date().addingTimeInterval(30))
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken("short", expires: soon)), .json(Fixtures.sessionToken("long")))
        let connection = connection(transport)
        let first = try await connection.currentToken(forceRefresh: false)
        #expect(first.token == "short")
        let second = try await connection.currentToken(forceRefresh: false)
        #expect(second.token == "long")
    }

    @Test func theStreamOpensFromTheWorkspaceCursorAndStopsWhenTheMachineSleeps() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        // The command id is minted inside `open`, so the fake answers whatever it was sent.
        let echo = EchoTransport(inner: transport, result: .workspace(Records.workspace(cursor: 77)))
        let live = WorkspaceConnection(workspaceID: "01k5ws", api: Fixtures.api(transport), machine: MachineClient(transport: echo), sleep: { _ in await Task.yield() })
        transport.on("GET", "/_bloom/v1/events", .init(status: 200, body: Data(), headers: ["Bloom-Stream-ID": "s1"], lines: [
            "event: message", "id: 80", "data: " + Records.json(WorkspaceEvent.message(Records.message(3, cursor: 80))), "",
            ": keep-alive", "",
            "event: sleeping", "data: " + Records.json(WorkspaceEvent.sleeping), "",
        ]))
        await live.open()
        var seen: [WorkspaceConnection.Update] = []
        for await update in live.updates {
            seen.append(update)
            if update == .phase(.asleep) { break }
        }
        let events = transport.requests(to: "/_bloom/v1/events")
        #expect(events.first?.value(forHTTPHeaderField: "Last-Event-ID") == "77")
        #expect(seen.contains(.snapshot(Records.workspace(cursor: 77))))
        #expect(seen.contains(.event(.message(Records.message(3, cursor: 80)))))
        #expect(seen.contains(.phase(.live)))
        #expect(await live.currentPhase == .asleep)
    }

    @Test func machineNotReadyWaitsAndSaysSo() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(#"{"code": "machine_not_ready", "message": "Still starting.", "retry_after": 5}"#, status: 409))
        let connection = connection(transport)
        await connection.open()
        for await update in connection.updates {
            if case .phase(.notReady(let message, let retry)) = update {
                #expect(message == "Still starting.")
                #expect(retry == 5)
                break
            }
        }
        await connection.close()
    }

    @Test func anArchivedWorkspaceStops() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(#"{"code": "workspace_archived", "message": "Archived."}"#, status: 409))
        let connection = connection(transport)
        await connection.open()
        for await update in connection.updates where update == .phase(.archived) { break }
        #expect(await connection.currentPhase == .archived)
    }
}

/// Answers every command with a fixed result under whatever command id it was sent, and passes
/// everything else to the fake.
struct EchoTransport: HTTPTransport {
    let inner: FakeTransport
    let result: OperationResult

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.path().hasSuffix("/_bloom/v1/rpc") == true, let body = request.httpBody,
              let command = try? WireJSON.decode(CommandRequest.self, from: body) else {
            return try await inner.data(for: request)
        }
        let data = try WireJSON.encode(CommandReply(commandID: command.commandID, result: result))
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        try await inner.lines(for: request)
    }
}

@Suite struct WorkspaceConnectionLifecycleTests {
    private func stream(_ events: [WorkspaceEvent]) -> FakeTransport.Answer {
        var lines: [String] = []
        for event in events {
            lines.append("event: \(event.kind)")
            if let cursor = event.cursor { lines.append("id: \(cursor)") }
            lines += ["data: " + Records.json(event), ""]
        }
        return .init(status: 200, body: Data(), headers: ["Bloom-Stream-ID": "s1"], lines: lines)
    }

    private func connection(_ transport: FakeTransport) -> WorkspaceConnection {
        WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(transport),
            machine: MachineClient(transport: EchoTransport(inner: transport, result: .workspace(Records.workspace(cursor: 77)))),
            sleep: { _ in await Task.yield() }
        )
    }

    @Test func wakingAfterSleepResumesFromTheCursorWithoutReadingTheWorkspaceAgain() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events",
                     stream([.message(Records.message(3, cursor: 80)), .sleeping]),
                     stream([.sleeping]))
        let live = connection(transport)
        await live.open()
        for await update in live.updates where update == .phase(.asleep) { break }
        await live.resume()
        var sleeps = 0
        for await update in live.updates where update == .phase(.asleep) {
            sleeps += 1
            break
        }
        #expect(sleeps == 1)
        #expect(transport.requests(to: "/_bloom/v1/events").map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == ["77", "80"])
    }

    @Test func aStreamRefusedTwiceStops() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events", .json(#"{"code": "unauthenticated", "message": "Access was removed."}"#, status: 401))
        let live = connection(transport)
        await live.open()
        for await update in live.updates {
            if case .phase(.noAccess(let message)) = update {
                #expect(message == "Access was removed.")
                break
            }
        }
        #expect(transport.requests(to: "/_bloom/v1/events").count == 2)
    }

    @Test func aSuspendedConnectionKeepsItsCursor() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events", stream([.message(Records.message(3, cursor: 90)), .sleeping]))
        let live = connection(transport)
        await live.open()
        for await update in live.updates where update == .phase(.asleep) { break }
        await live.suspend()
        #expect(await live.currentPhase == .closed)
        await live.resume()
        for await update in live.updates where update == .phase(.asleep) { break }
        #expect(transport.requests(to: "/_bloom/v1/events").last?.value(forHTTPHeaderField: "Last-Event-ID") == "90")
    }
}

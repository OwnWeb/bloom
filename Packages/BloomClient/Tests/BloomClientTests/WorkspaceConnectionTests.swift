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
            if case .phase(.notReady(let message, let retry, _)) = update {
                #expect(message == "Still starting.")
                #expect(retry == 5)
                break
            }
        }
        await connection.close()
    }

    @Test func sharingInProgressIsWaitedOutLikeAMachineThatIsNotReady() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(#"{"code": "sharing_in_progress", "message": "Sharing is being set up.", "retry_after": 5}"#, status: 409))
        let connection = connection(transport)
        await connection.open()
        for await update in connection.updates {
            if case .phase(.notReady(let message, let retry, _)) = update {
                #expect(message == "Sharing is being set up.")
                #expect(retry == 5)
                break
            }
        }
        await connection.close()
    }

    /// **The banner appeared and vanished every few seconds while nothing changed**, which the
    /// owner reported as a workspace that "sometimes goes away and comes back". A machine that is
    /// still being made refuses every attempt, and each attempt announced itself as a new
    /// connection first: `notReady` draws a banner, `connecting` draws none, so the loop blinked it
    /// on and off for as long as the machine took. A phase that already says "still trying, and
    /// here is why" now survives the next attempt.
    ///
    /// The phases are collected in a task of their own and the wait is on the transport, because
    /// with the fix in place there is nothing left to wait for on the stream: the whole point is
    /// that no further phase is yielded. A test that awaited one would hang for exactly the reason
    /// it is testing.
    @Test func aMachineStillStartingSaysSoOnceRatherThanBlinking() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token",
                     .json(#"{"code": "machine_not_ready", "message": "Still starting.", "retry_after": 5}"#, status: 409))
        let connection = connection(transport)
        let log = PhaseLog()
        let watcher = Task { [connection] in
            for await update in connection.updates {
                if case .phase(let phase) = update { log.record(phase) }
            }
        }
        await connection.open()
        let retried = await transport.waitForRequests(to: "/session-token", count: 3)
        await connection.close()
        watcher.cancel()

        let starting = log.phases.filter { if case .notReady = $0 { true } else { false } }
        #expect(retried, "the loop did not try again")
        #expect(starting.count == 1, "the banner came and went: \(log.phases)")
    }

    @Test func cancellingACommandStopsItsRetryWait() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("POST", "/_bloom/v1/rpc", .dropped())
        let connection = WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(transport), machine: MachineClient(transport: transport)
        )
        let command = Task {
            try await connection.perform(.markRead(chatID: "c1", seq: 1), commandID: "cancelled")
        }
        let sent = await transport.waitForRequests(to: "/_bloom/v1/rpc", count: 1)
        #expect(sent, "the command was never sent")
        command.cancel()
        do {
            _ = try await command.value
            Issue.record("Expected cancellation")
        } catch let failure as WorkspaceConnection.CommandFailure {
            #expect(failure == .cancelled)
        }
        #expect(transport.requests(to: "/_bloom/v1/rpc").count == 1)
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
    /// The answer to the `workspace` read every first connection starts with, when `result` is
    /// meant for a command sent beside it.
    var snapshot: OperationResult?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.path().hasSuffix("/_bloom/v1/rpc") == true, let body = request.httpBody,
              let command = try? WireJSON.decode(CommandRequest.self, from: body) else {
            return try await inner.data(for: request)
        }
        let answer = if case .workspace = command.operation, let snapshot { snapshot } else { result }
        let data = try WireJSON.encode(CommandReply(commandID: command.commandID, result: answer))
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

    /// **The sentence about waking has an end.** A machine runbloom.app last saw asleep, asked and
    /// not answering, said "this usually takes a few seconds" for as long as the window stayed
    /// open. The connection keeps trying either way; what changes is that it stops promising.
    @Test func aMachineThatDoesNotWakeIsSaidToNotHaveWoken() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken(awake: false)))
        // Never answers, which is what a machine that is not coming back looks like from here.
        transport.on("POST", "/_bloom/v1/rpc", .dropped())
        transport.on("GET", "/_bloom/v1/events", .dropped())
        let live = WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(transport), machine: MachineClient(transport: transport),
            sleep: { _ in await Task.yield() }
        )
        await live.open()
        for await update in live.updates {
            if case .phase(.notWaking) = update { break }
        }
        await live.close()
        // Nothing is asserted here about the request that does the waking. Every test in this
        // suite that gets a snapshot only passes because the connection asks the machine rather
        // than only runbloom.app, which is the mechanism: a request to the machine URL is what
        // wakes one, and a reserved wake is bookkeeping on the awake limit. Asserting it again
        // here would be a race, because this harness's sleeps take no time at all.
    }

    /// A machine whose build failed used to be drawn as "Reconnecting…" for ever, because an
    /// unrecognised refusal fell through to the retry branch. The hint decides it now.
    @Test func aRefusalWithNoRetryHintStopsRatherThanRetrying() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token",
                     .json(#"{"code": "machine_failed", "message": "This workspace's machine could not be built."}"#, status: 409))
        let live = WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(transport), machine: MachineClient(transport: transport),
            sleep: { _ in await Task.yield() }
        )
        await live.open()
        for await update in live.updates {
            if case .phase(.unavailable(let message)) = update {
                #expect(message == "This workspace's machine could not be built.")
                break
            }
        }
        await live.close()
        // Once. A stop is a stop, which is the whole difference from the retry branch it used to
        // fall into.
        #expect(transport.requests(to: "/session-token").count == 1)
    }

    /// And the other half of the rule: a refusal that carries a hint is still a wait.
    @Test func aRefusalWithARetryHintIsStillAWait() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token",
                     .json(#"{"code": "machine_not_ready", "message": "Starting.", "retry_after": 2}"#, status: 409),
                     .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events", .dropped())
        let live = WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(transport), machine: MachineClient(transport: transport),
            sleep: { _ in await Task.yield() }
        )
        await live.open()
        for await update in live.updates {
            if case .phase(.notReady(let message, let retryAfter, _)) = update {
                #expect(message == "Starting.")
                #expect(retryAfter == 2)
                break
            }
        }
        await live.close()
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

    /// And the other half of the same rule: a workspace this connection has already had a stream
    /// from is reconnecting, not starting, whatever runbloom.app says while the two catch up.
    @Test func aWorkspaceThatHasBeenLiveDoesNotGoBackToStarting() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()),
                     .json(#"{"code": "machine_not_ready", "message": "Still starting.", "retry_after": 2}"#, status: 409))
        transport.on("GET", "/_bloom/v1/events", stream([.message(Records.message(3, cursor: 90))]), .dropped())
        let live = connection(transport)
        await live.open()
        var phases: [WorkspaceConnection.Phase] = []
        for await update in live.updates {
            guard case .phase(let phase) = update else { continue }
            phases.append(phase)
            if case .retrying = phase { break }
            if case .notReady = phase { break }
        }
        await live.close()
        #expect(phases.contains(.live))
        #expect(!phases.contains { if case .notReady = $0 { true } else { false } }, "went back to starting: \(phases)")
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

    /// **A session token lives minutes and an open workspace lives hours, so a stream closing
    /// because the token ran out is the ordinary case rather than an edge one.** The machine says
    /// `closing` with `token_expired` and the client reopens at once, from its cursor and with a
    /// token it fetches again, and no banner is raised for it: nothing was missed and
    /// there is nothing for a reader to do. The web client handled the event, reopened nothing, and
    /// went deaf with its composer still accepting messages, which is the worst shape a live view
    /// can fail in.
    @Test func aStreamClosedByAnExpiredTokenReopensAtOnceFromItsCursor() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken("old")), .json(Fixtures.sessionToken("new")))
        transport.on("GET", "/_bloom/v1/events",
                     stream([.message(Records.message(3, cursor: 90)), .closing(WireError(.tokenExpired, "Expired."))]),
                     stream([.sleeping]))
        let live = connection(transport)
        await live.open()
        // Nothing calls `resume` here, which is the whole assertion: the second stream is the
        // client's own doing, and it starts where the first one stopped.
        for await update in live.updates where update == .phase(.asleep) { break }
        let events = transport.requests(to: "/_bloom/v1/events")
        #expect(events.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == ["77", "90"])
    }

    /// And the reopen is a loop rather than a handler, which is the second half of the same bug: a
    /// machine that is down or asleep refuses the attempt the expiry provoked, and one refused
    /// attempt must not become permanent silence. The third answer here is the machine back again.
    @Test func aReopenThatFailsIsTriedAgainRatherThanLeavingTheStreamShut() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events",
                     stream([.message(Records.message(3, cursor: 90)), .closing(WireError(.tokenExpired, "Expired."))]),
                     .dropped(),
                     stream([.sleeping]))
        let live = connection(transport)
        await live.open()
        for await update in live.updates where update == .phase(.asleep) { break }
        #expect(transport.requests(to: "/_bloom/v1/events").count == 3)
        #expect(transport.requests(to: "/_bloom/v1/events").last?.value(forHTTPHeaderField: "Last-Event-ID") == "90")
    }

    /// **And the waits it goes round with are the table, in order, settling rather than growing.**
    /// Asserted from what the loop asked for, because a test that waited out the real delays would
    /// have put the wall clock in the assertion and a busy machine could move it. What this catches
    /// is the only way those numbers realistically go wrong: somebody reordering or truncating
    /// `retryDelays`, which would shorten the gap the whole schedule exists to survive.
    @Test func aStreamThatKeepsFailingBacksOffThroughTheTableAndSettlesAtThirty() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events", answers: Array(repeating: .dropped(), count: 10) + [stream([.sleeping])])
        let waits = SleepLog()
        let live = WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(transport),
            machine: MachineClient(transport: EchoTransport(inner: transport, result: .workspace(Records.workspace(cursor: 77)))),
            sleep: waits.sleep
        )
        await live.open()
        for await update in live.updates where update == .phase(.asleep) { break }
        // Ten refusals ask for ten waits, of which 0.5 and 2 are dropped with the notice holds
        // they cannot be told apart from, leaving these eight. See `SleepLog.backoffSeconds`. The
        // wait after them belongs to the stream that finally opened, which refreshes its token a
        // minute before it expires and is no part of a backoff.
        //
        // Worth leaving in writing, because it is the only realistic way these numbers go wrong:
        // reordering any of the eight moves this sequence, and truncating `retryDelays` repeats an
        // earlier value where the thirties are, so either still fails here. What dropping 0.5 and 2
        // does give up is a swap of those two with each other, which is the one edit this cannot
        // see. They are the two shortest waits; the gap the schedule exists to survive is in the
        // eight that are asserted.
        #expect(Array(waits.backoffSeconds.prefix(8)) == [1, 3, 5, 8, 13, 21, 30, 30])
    }

    /// The disappearance this most often meets is a runner restarting itself, about eight seconds.
    /// A command has to outlive it: three attempts a second apart gave up after five, which
    /// guaranteed a prompt sent in that window failed seconds before the machine came back.
    @Test func aCommandOutlivesARunnerRestart() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on(
            "POST", "/_bloom/v1/rpc",
            .dropped(), .dropped(), .dropped(), .dropped(),
            .json(Records.json(CommandReply(commandID: "cmd-1", result: .queued(promptID: "p1"))))
        )
        let waits = Waits()
        let connection = WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(transport), machine: MachineClient(transport: transport),
            sleep: { await waits.record($0) }
        )
        let result = try await connection.perform(.send(chatID: "c1", text: "Run the tests"), commandID: "cmd-1")
        #expect(result == .queued(promptID: "p1"))
        let sent = transport.requests(to: "/_bloom/v1/rpc").compactMap(\.httpBody)
            .compactMap { try? WireJSON.decode(CommandRequest.self, from: $0) }
        #expect(sent.count == 5, "it gave up before the machine came back")
        #expect(Set(sent.map(\.commandID)) == ["cmd-1"], "a retry must be the same command")
        // The waits grow rather than repeating, and together they cover the eight seconds a
        // restart takes.
        let slept = await waits.durations
        #expect(slept.count == 4)
        #expect(slept.reduce(Duration.zero, +) > .seconds(6))
    }
}

/// **A Cloud workspace sat on "Starting" under a message for minutes after its turn had ended.**
/// Every send was answered, and the machine's own log showed no event stream open for three
/// quarters of an hour: the last one had been closed from this side and nothing had asked again,
/// so the turn's end was never heard. These are the connection's half of that: a stream that ends
/// is asked for again, and a label that says one is open is not taken on trust.
@Suite struct WorkspaceConnectionReopeningTests {
    private func stream(_ events: [WorkspaceEvent]) -> FakeTransport.Answer {
        var lines: [String] = []
        for event in events {
            lines.append("event: \(event.kind)")
            if let cursor = event.cursor { lines.append("id: \(cursor)") }
            lines += ["data: " + Records.json(event), ""]
        }
        return .init(status: 200, body: Data(), headers: ["Bloom-Stream-ID": "s1"], lines: lines)
    }

    private func connection(_ transport: some HTTPTransport, api: FakeTransport) -> WorkspaceConnection {
        WorkspaceConnection(
            workspaceID: "01k5ws", api: Fixtures.api(api), machine: MachineClient(transport: transport),
            sleep: { _ in await Task.yield() }
        )
    }

    /// A stream the machine ends with neither `sleeping` nor `closing` is a drop, and is reopened
    /// from where it got to with nobody calling anything.
    @Test func aStreamThatEndsWithoutSayingWhyIsOpenedAgainFromItsCursor() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events", stream([.message(Records.message(3, cursor: 90))]), stream([.sleeping]))
        let echo = EchoTransport(inner: transport, result: .workspace(Records.workspace(cursor: 77)))
        let live = connection(echo, api: transport)
        await live.open()
        for await update in live.updates where update == .phase(.asleep) { break }
        let events = transport.requests(to: "/_bloom/v1/events")
        #expect(events.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == ["77", "90"])
    }

    /// **The loop was cancelled, and then said `live` anyway.** `suspend()` cancels the stream
    /// loop, but a loop parked on the stream's response head carries on when the answer lands, and
    /// it wrote `live` over the `closed` it had been cancelled for before leaving. What was left
    /// said `live` with no stream behind it, and `resume` returned on that word, so the workspace
    /// stayed deaf however often it was opened.
    @Test func aLoopCancelledWhileOpeningLeavesNothingThatStopsTheNextOpen() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events", stream([.sleeping]))
        let held = HeldStreamTransport(inner: EchoTransport(inner: transport, result: .workspace(Records.workspace(cursor: 77))))
        let live = connection(held, api: transport)

        await live.open()
        await held.waitUntilAsked()
        await live.suspend()
        held.answer()
        // The cancelled loop has read the answer and let go of it, which is after the line that
        // used to say `live`.
        await held.waitUntilReleased()

        await live.resume()
        let reopened = await transport.waitForRequests(to: "/_bloom/v1/events", count: 1)
        #expect(reopened, "resume believed a phase no stream was behind")
        await live.close()
    }

    /// And the same state met by a send rather than by opening the workspace: somebody still
    /// sending is the plainest sign a stream is wanted, so a command that finds the phase saying
    /// `live` with no stream behind it asks for one.
    ///
    /// The phase is put there by hand because the fix above leaves no public route to it any
    /// more, and this is the half that has to hold for the next route nobody has found yet.
    @Test func aSendWhileNoStreamIsRunningOpensOne() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events", stream([.sleeping]))
        let echo = EchoTransport(inner: transport, result: .queued(promptID: "p1"), snapshot: .workspace(Records.workspace(cursor: 77)))
        let live = connection(echo, api: transport)
        await live.setPhaseForTesting(.live)

        let result = try await live.perform(.send(chatID: "c1", text: "Run the tests"), commandID: "cmd-1")
        #expect(result == .queued(promptID: "p1"))
        let reopened = await transport.waitForRequests(to: "/_bloom/v1/events", count: 1)
        #expect(reopened, "a send went through with no stream open and did not ask for one")
        await live.close()
    }

    /// A workspace somebody left is not reopened by a command going past it, which is what keeps
    /// `suspend` meaning anything: a held read in flight as the window moves on would otherwise
    /// open a stream for a workspace nobody is looking at, and keep it open.
    @Test func aSendToASuspendedWorkspaceDoesNotOpenItsStream() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken()))
        transport.on("GET", "/_bloom/v1/events", stream([.sleeping]))
        let live = connection(EchoTransport(inner: transport, result: .queued(promptID: "p1")), api: transport)
        await live.suspend()

        _ = try await live.perform(.send(chatID: "c1", text: "Run the tests"), commandID: "cmd-1")
        #expect(transport.requests(to: "/_bloom/v1/events").isEmpty)
        #expect(await live.currentPhase == .closed)
    }
}

/// Holds the first event stream request until the test says so, answers it with a stream that
/// stays open, and reports when that stream is let go of. Everything after the first goes to the
/// transport underneath.
///
/// The hold is what a response already on its way looks like to a loop that has just been
/// cancelled: the request does not notice, and the answer arrives anyway.
final class HeldStreamTransport: HTTPTransport, @unchecked Sendable {
    let inner: any HTTPTransport
    private let lock = NSLock()
    private var held = false
    private let asked: AsyncStream<Void>
    private let askedContinuation: AsyncStream<Void>.Continuation
    private var isAnswered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let released: AsyncStream<Void>
    private let releasedContinuation: AsyncStream<Void>.Continuation

    init(inner: any HTTPTransport) {
        self.inner = inner
        (asked, askedContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .unbounded)
        (released, releasedContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .unbounded)
    }

    func waitUntilAsked() async {
        for await _ in asked { return }
    }

    func answer() {
        let waiting = lock.withLock {
            isAnswered = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }

    func waitUntilReleased() async {
        for await _ in released { return }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await inner.data(for: request)
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let first = lock.withLock {
            defer { held = true }
            return !held
        }
        guard first else { return try await inner.lines(for: request) }
        askedContinuation.yield()
        // A checked continuation rather than a stream, because iterating a stream returns at once
        // in a cancelled task and this hold has to outlast the cancellation: see the type's note.
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            let now = lock.withLock {
                if isAnswered { return true }
                waiter = waiting
                return false
            }
            if now { waiting.resume() }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Bloom-Stream-ID": "held"])!
        let stream = AsyncThrowingStream<String, any Error> { [releasedContinuation] continuation in
            continuation.onTermination = { _ in releasedContinuation.yield() }
        }
        return (response, stream)
    }
}

/// The sleeps a connection asked for, recorded rather than taken.
private actor Waits {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) { durations.append(duration) }
}

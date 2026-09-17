import BloomProtocol
import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("Cloud workspace runtime", .scratchDirectory, .tags(.persistence))
struct RemoteWorkspaceRuntimeTests {
    static let freek = MessageAuthor(userID: "01k5bx7j9d3v2r8q6m4n0p1s2t", name: "Freek")
    static let seb = MessageAuthor(userID: "01k5bx7j9d3v2r8q6m4n0p1s2v", name: "Seb")

    struct Fixture {
        let store: Store
        let workspace: Workspace
        let session: Session
        let runtime: WorkspaceRuntime
        let runners: RemoteTestRunners
    }

    func fixture(gate: any RemoteTurnGate = UngatedTurns()) async throws -> Fixture {
        let store = try makeTestStore("remote-runtime")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let path = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Queue retries", branch: "queue-retries", path: path, baseBranch: "main"))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let runners = RemoteTestRunners()
        let runtime = WorkspaceRuntime(
            store: store, workspaceID: workspace.id, gate: gate,
            makeRunner: { session, _, store, environment, _ in runners.make(session: session, store: store, environment: environment) },
            installedAgents: { [.claudeCode, .codex] }, models: { _ in [] }, runnerExitGrace: .milliseconds(50)
        )
        try await runtime.start()
        return Fixture(store: store, workspace: workspace, session: session, runtime: runtime, runners: runners)
    }

    static func caller(_ author: MessageAuthor, abilities: Set<String> = ["view", "prompt", "terminal", "files"]) -> RemoteCaller {
        RemoteCaller(author: author, abilities: abilities, sessionToken: "token-for-\(author.userID)")
    }

    @Test("a prompt is queued under its author and reaches the agent with that author on the row")
    func sendRecordsTheAuthor() async throws {
        let fixture = try await fixture()
        let reply = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Run the tests")),
                                                  as: Self.caller(Self.freek))
        guard case .queued = reply.result else { Issue.record("Expected queued, got \(String(describing: reply.error))"); return }
        await waitUntil("the agent received the prompt") { fixture.runners.sent.withLock { $0 } == ["Run the tests"] }
        let messages = try await fixture.store.messages(sessionID: fixture.session.id)
        let user = try #require(messages.first { $0.kind == .user })
        #expect(user.author == Self.freek)
        await fixture.runtime.shutdown()
    }

    @Test("a retried command is answered from the journal and never runs twice")
    func retriesAreAnsweredOnce() async throws {
        let fixture = try await fixture()
        let request = CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Once only"), commandID: "retry-1")
        let first = await fixture.runtime.respond(to: request, as: Self.caller(Self.freek))
        let second = await fixture.runtime.respond(to: request, as: Self.caller(Self.freek))
        #expect(first == second)
        await waitUntil("the agent received the prompt") { fixture.runners.sent.withLock { $0 }.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.runners.sent.withLock { $0 } == ["Once only"])

        let reused = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Something else"), commandID: "retry-1"),
                                                   as: Self.caller(Self.freek))
        #expect(reused.error?.code == .commandIDReused)

        // The same id from somebody else is their own command, never a copy of Freek's reply.
        let other = await fixture.runtime.respond(to: CommandRequest(.renameChat(chatID: fixture.session.id.rawValue, title: "Theirs"), commandID: "retry-1"),
                                                  as: Self.caller(Self.seb))
        #expect(other.error == nil)
        await fixture.runtime.shutdown()
    }

    @Test("a command the server stopped in the middle of is unknown rather than run again")
    func anInterruptedCommandIsUnknown() async throws {
        let fixture = try await fixture()
        let request = CommandRequest(.renameChat(chatID: fixture.session.id.rawValue, title: "Review"), commandID: "interrupted")
        let entry = #"{"recorded_at":"2026-09-17T10:00:00.000Z","request":"# + String(decoding: try WireJSON.encode(request), as: UTF8.self) + "}"
        try await fixture.store.setSetting("remote.command.\(Self.freek.userID).interrupted", entry)
        let reply = await fixture.runtime.respond(to: request, as: Self.caller(Self.freek))
        #expect(reply.error?.code == .outcomeUnknown)
        await fixture.runtime.shutdown()
    }

    @Test("an operation outside the token's abilities is refused")
    func abilitiesAreChecked() async throws {
        let fixture = try await fixture()
        let viewer = Self.caller(Self.seb, abilities: ["view"])
        let refused = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Hello")), as: viewer)
        #expect(refused.error?.code == .missingAbility)
        let read = await fixture.runtime.respond(to: CommandRequest(.workspace), as: viewer)
        guard case .workspace(let snapshot) = read.result else { Issue.record("A viewer could not read the workspace"); return }
        #expect(snapshot.chats.map(\.id) == [fixture.session.id.rawValue])
        #expect(snapshot.workspace.name == "Queue retries")
        await fixture.runtime.shutdown()
    }

    @Test("another protocol version is refused with its own code")
    func versionsAreChecked() async throws {
        let fixture = try await fixture()
        var request = CommandRequest(.workspace)
        request.version = 2
        let reply = await fixture.runtime.respond(to: request, as: Self.caller(Self.freek))
        #expect(reply.error?.code == .unsupportedVersion)
        await fixture.runtime.shutdown()
    }

    @Test("a turn refused for a limit stays queued and marked, and starts once the limit lifts")
    func limitsBlockAndClear() async throws {
        let gate = RemoteTestGate()
        gate.refusal.withLock { $0 = .blocked(DeliveryBlock(limit: "concurrent_machines", message: "Your team already has 20 Cloud workspaces running.")) }
        let fixture = try await fixture(gate: gate)
        let reply = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "When there is room")),
                                                  as: Self.caller(Self.freek))
        guard case .queued = reply.result else { Issue.record("Expected queued"); return }
        #expect(gate.registered.withLock { $0 }.first?.token == "token-for-\(Self.freek.userID)")
        await waitUntil("the prompt was marked blocked") {
            (try? await fixture.store.pendingDeliveries(sessionID: fixture.session.id).first?.block?.limit) == "concurrent_machines"
        }
        #expect(fixture.runners.sent.withLock { $0 }.isEmpty)

        gate.refusal.withLock { $0 = nil }
        await fixture.runtime.limitsCleared()
        await waitUntil("the prompt went once the limit lifted") { fixture.runners.sent.withLock { $0 } == ["When there is room"] }
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test("the agent process keeps its key across turns on the same key, and is relaunched for another")
    func keysDecideRelaunches() async throws {
        let gate = RemoteTestGate()
        let fixture = try await fixture(gate: gate)
        let chat = fixture.session.id.rawValue
        gate.keys.withLock { $0 = [Self.freek.userID: "team-key", Self.seb.userID: "team-key"] }

        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "First")), as: Self.caller(Self.freek))
        await waitUntil("the first turn ran") { fixture.runners.sent.withLock { $0 }.count == 1 }
        await fixture.runners.finishTurn()
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Second")), as: Self.caller(Self.seb))
        await waitUntil("the second turn ran") { fixture.runners.sent.withLock { $0 }.count == 2 }
        #expect(fixture.runners.launches.withLock { $0 }.count == 1, "Two people on the team key share one process")
        #expect(fixture.runners.launches.withLock { $0 }.first?["ANTHROPIC_API_KEY"] == "team-key")

        await fixture.runners.finishTurn()
        gate.keys.withLock { $0[Self.seb.userID] = "seb-personal-key" }
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Third")), as: Self.caller(Self.seb))
        await waitUntil("the third turn ran") { fixture.runners.sent.withLock { $0 }.count == 3 }
        let launches = fixture.runners.launches.withLock { $0 }
        #expect(launches.count == 2, "A different key needs its own process")
        #expect(launches.last?["ANTHROPIC_API_KEY"] == "seb-personal-key")
        #expect(gate.ended.withLock { $0 }.count >= 2, "Every finished turn is ended with runbloom.app")
        await fixture.runtime.shutdown()
    }

    @Test("sharing stops a turn on a personal key with a row saying why, and the queue carries on on the team key")
    func sharingRetiresPersonalKeys() async throws {
        let gate = RemoteTestGate()
        let fixture = try await fixture(gate: gate)
        let chat = fixture.session.id.rawValue
        gate.keys.withLock { $0 = [Self.freek.userID: "freek-personal-key", Self.seb.userID: "team-key"] }

        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Mine")), as: Self.caller(Self.freek))
        await waitUntil("the personal turn is running") { fixture.runners.sent.withLock { $0 }.count == 1 }
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Theirs")), as: Self.caller(Self.seb))

        await fixture.runtime.becameShared()
        await fixture.runtime.becameShared()
        await waitUntil("the queued prompt went on the team key") { fixture.runners.sent.withLock { $0 } == ["Mine", "Theirs"] }
        let launches = fixture.runners.launches.withLock { $0 }
        #expect(launches.map { $0["ANTHROPIC_API_KEY"] } == ["freek-personal-key", "team-key"])
        let rows = try await fixture.store.messages(sessionID: fixture.session.id).filter { $0.kind == .error }
        #expect(rows.count == 1, "Sharing twice stops once")
        let payload = rows.first.map { String(decoding: $0.payload, as: UTF8.self) } ?? ""
        #expect(payload.contains("stoppedForSharing"))
        await fixture.runtime.shutdown()
    }

    @Test("a grant supersedes personal credentials only where it shows the workspace is shared")
    func supersedingIsPerAgent() {
        let team = RemoteTurnGrant(agentKeys: [.codex: RemoteAgentKey(key: "k", identity: "i", source: "team")], environment: ["A": "b"])
        #expect(team.supersedes(["codex"]))
        #expect(!team.supersedes(["claude"]), "A team key for Codex says nothing about a personal Claude key")
        #expect(!team.supersedes(["environment"]), "Personal environment still arrives, so the workspace is not shared")
        #expect(RemoteTurnGrant().supersedes(["environment"]))
        #expect(team.personalMarks(for: [.codex]) == ["environment"])
    }

    @Test("prompts from two people queue behind a running turn in the order they arrived")
    func promptsQueueInArrivalOrder() async throws {
        let fixture = try await fixture()
        let chat = fixture.session.id.rawValue
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "One")), as: Self.caller(Self.freek))
        await waitUntil("the first turn is running") { fixture.runners.sent.withLock { $0 }.count == 1 }
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Two")), as: Self.caller(Self.seb))
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Three")), as: Self.caller(Self.freek))
        let reply = await fixture.runtime.respond(to: CommandRequest(.transcript(chatID: chat, afterSeq: -1, limit: nil)), as: Self.caller(Self.freek))
        guard case .transcript(let transcript) = reply.result else { Issue.record("No transcript"); return }
        #expect(transcript.queue.prompts.map(\.text) == ["Two", "Three"])
        #expect(transcript.queue.prompts.map(\.author?.name) == ["Seb", "Freek"])
        #expect(fixture.runners.sent.withLock { $0 } == ["One"], "Nobody's message is injected into a running turn")
        await fixture.runners.finishTurn()
        await waitUntil("the second prompt went") { fixture.runners.sent.withLock { $0 }.count == 2 }
        await fixture.runners.finishTurn()
        await waitUntil("the third prompt went") { fixture.runners.sent.withLock { $0 } == ["One", "Two", "Three"] }
        await fixture.runtime.shutdown()
    }

    @Test("the event stream sends state, then the rows after the cursor, then new rows once each")
    func eventsReplayAndFollow() async throws {
        let fixture = try await fixture()
        let first = try await fixture.store.appendNext(sessionID: fixture.session.id, kind: .assistantText, payload: Data(#"{"text":"old"}"#.utf8))
        let second = try await fixture.store.appendNext(sessionID: fixture.session.id, kind: .assistantText, payload: Data(#"{"text":"missed"}"#.utf8))
        let stream = try await fixture.runtime.openEvents(for: Self.caller(Self.freek), after: first.id)
        var iterator = stream.makeAsyncIterator()
        var kinds: [String] = []
        var cursors: [Int64] = []
        while let event = await iterator.next() {
            kinds.append(event.kind)
            if let cursor = event.cursor { cursors.append(cursor) }
            if event.cursor == second.id { break }
        }
        #expect(kinds.contains("chat") && kinds.contains("queue") && kinds.contains("presence"))
        #expect(cursors == [second.id], "Only the row after the cursor is replayed")

        let third = try await fixture.store.appendNext(sessionID: fixture.session.id, kind: .assistantText, payload: Data(#"{"text":"new"}"#.utf8))
        while let event = await iterator.next() {
            if let cursor = event.cursor {
                #expect(cursor == third.id)
                break
            }
        }
        await fixture.runtime.shutdown()
    }

    @Test("revoking somebody removes their queued prompts and leaves everybody else's")
    func revokeRemovesTheirPrompts() async throws {
        let fixture = try await fixture()
        let chat = fixture.session.id.rawValue
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "One")), as: Self.caller(Self.freek))
        await waitUntil("the first turn is running") { fixture.runners.sent.withLock { $0 }.count == 1 }
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Two")), as: Self.caller(Self.seb))
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Three")), as: Self.caller(Self.freek))
        await fixture.runtime.revoke(userID: Self.seb.userID)
        let reply = await fixture.runtime.respond(to: CommandRequest(.transcript(chatID: chat, afterSeq: -1, limit: nil)), as: Self.caller(Self.freek))
        guard case .transcript(let transcript) = reply.result else { Issue.record("No transcript"); return }
        #expect(transcript.queue.prompts.map(\.text) == ["Three"])
        #expect(transcript.queue.error == nil, "The chat is not paused for the people still in it")
        await fixture.runners.finishTurn()
        await waitUntil("Freek's next prompt went") { fixture.runners.sent.withLock { $0 } == ["One", "Three"] }
        await fixture.runtime.shutdown()
    }

    @Test("a question is answered by the first person to answer it")
    func firstAnswerWins() async throws {
        let fixture = try await fixture()
        let chat = fixture.session.id.rawValue
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Delete the cache")), as: Self.caller(Self.freek))
        await waitUntil("the turn is running") { fixture.runners.sent.withLock { $0 }.count == 1 }
        let ask = try #require(PermissionAsk.decode(payload: Data(PermissionAskTests.realAsk.utf8)))
        try await fixture.store.appendPermissionAsk(sessionID: fixture.session.id, ask: ask)
        let first = await fixture.runtime.respond(to: CommandRequest(.answer(chatID: chat, requestID: ask.requestID, answer: .allowOnce)), as: Self.caller(Self.seb))
        #expect(first.result == .accepted, "\(String(describing: first.error))")
        let second = await fixture.runtime.respond(to: CommandRequest(.answer(chatID: chat, requestID: ask.requestID, answer: .deny(message: nil, endsTurn: false))), as: Self.caller(Self.freek))
        #expect(second.error?.code == .alreadyAnswered)
        await fixture.runtime.shutdown()
    }

    @Test("prompts wait while setup runs, and go once it finishes however it ended")
    func setupHoldsPrompts() async throws {
        let fixture = try await fixture()
        await fixture.runtime.setupStepStarted("setup")
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "After setup")), as: Self.caller(Self.freek))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.runners.sent.withLock { $0 }.isEmpty)
        await fixture.runtime.setupFinished()
        await waitUntil("the prompt went after setup") { fixture.runners.sent.withLock { $0 } == ["After setup"] }
        await fixture.runtime.shutdown()
    }

    @Test("changing the composer names who changed it")
    func composerChangesNameTheirAuthor() async throws {
        let fixture = try await fixture()
        let stream = try await fixture.runtime.openEvents(for: Self.caller(Self.freek), after: nil)
        let controls = ComposerControlsRecord(agent: "claude", model: "claude-opus-5", effort: "high", permissionMode: "acceptEdits", interactionMode: "build")
        let reply = await fixture.runtime.respond(to: CommandRequest(.setComposer(chatID: fixture.session.id.rawValue, controls: controls)), as: Self.caller(Self.seb))
        #expect(reply.result == .accepted)
        for await event in stream {
            if case .composer(_, let received, let changedBy) = event {
                #expect(received.model == "claude-opus-5")
                #expect(changedBy?.name == "Seb")
                break
            }
        }
        let stored = try await fixture.store.session(id: fixture.session.id)
        #expect(stored?.model == "claude-opus-5")
        await fixture.runtime.shutdown()
    }
}

/// Stands in for runbloom.app's turns: records registrations, answers starts with a key per
/// prompter, or refuses with whatever the test set.
final class RemoteTestGate: RemoteTurnGate {
    let registered = Mutex<[(turnID: String, token: String?, author: String?)]>([])
    let keys = Mutex<[String: String]>([:])
    let refusal = Mutex<RemoteTurnRefusal?>(nil)
    let ended = Mutex<[String]>([])

    func register(_ kind: RemoteTurnKind, chat: SessionID?, agent: AgentKind?, caller: RemoteCaller) async throws -> String {
        let id = "turn-\(UUID().uuidString.lowercased())"
        registered.withLock { $0.append((id, caller.sessionToken, caller.author?.userID)) }
        return id
    }

    func start(turnID: String) async throws -> RemoteTurnGrant {
        if let refusal = refusal.withLock({ $0 }) { throw refusal }
        let author = registered.withLock { $0.first { $0.turnID == turnID }?.author } ?? ""
        guard let key = keys.withLock({ $0[author] }) else { return RemoteTurnGrant() }
        let source = key.contains("personal") ? "personal" : "team"
        return RemoteTurnGrant(agentKeys: [.claudeCode: RemoteAgentKey(key: key, identity: "identity-of-\(key)", source: source)])
    }

    func end(turnID: String) async {
        ended.withLock { $0.append(turnID) }
    }
}

/// Every runner the runtime launched, what it was launched with, and what it was sent.
final class RemoteTestRunners: Sendable {
    let launches = Mutex<[[String: String]]>([])
    let sent = Mutex<[String]>([])
    let current = Mutex<RemoteTestRunner?>(nil)

    func make(session: Session, store: Store, environment: [String: String]) -> any SessionRunner {
        launches.withLock { $0.append(environment) }
        let runner = RemoteTestRunner(sessionID: session.id, store: store, owner: self)
        current.withLock { $0 = runner }
        return runner
    }

    func finishTurn() async {
        await current.withLock { $0 }?.finish()
    }
}

actor RemoteTestRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.claudeCode
    nonisolated let terminated = Mutex(false)
    nonisolated let sink = EventFanout<AgentEvent>()
    nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    nonisolated var presentationFeed: AgentPresentationFeed? { nil }
    var isProcessAlive: Bool { !terminated.withLock { $0 } }
    let sessionID: SessionID
    let store: Store
    let owner: RemoteTestRunners

    init(sessionID: SessionID, store: Store, owner: RemoteTestRunners) {
        self.sessionID = sessionID
        self.store = store
        self.owner = owner
    }

    func send(_ text: String, recording: Data?) async throws {
        owner.sent.withLock { $0.append(text) }
    }

    func sendDelivery(_ delivery: Delivery) async throws {
        try await store.beginDeliveryDispatch(id: delivery.id)
        owner.sent.withLock { $0.append(delivery.sent) }
        try await store.acceptDelivery(id: delivery.id)
    }

    nonisolated func cancelNow() { sink.yield(.result(AgentResult())) }
    nonisolated func terminateNow() { terminated.withLock { $0 = true } }

    func answer(requestID: String, decision: PermissionDecision) async {
        try? await store.resolvePermissionAsk(id: requestID, decision: decision.storedName)
    }

    func finish() {
        sink.yield(.result(AgentResult()))
    }
}

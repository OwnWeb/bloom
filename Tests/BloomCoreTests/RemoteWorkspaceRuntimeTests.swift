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

    @Test("a turn the machine restarted under ends with a row saying so, not with silence")
    func aRestartUnderATurnIsExplained() async throws {
        let first = try await fixture()
        // A turn in flight when the process goes: an update restarts the service and kills the
        // whole process group, so the row that would have closed this turn is never written.
        _ = try await first.store.upsert(first.session.with { $0.state = .running })
        await first.runtime.shutdown()

        // The server starting again on the same database, which is what the machine does.
        let second = WorkspaceRuntime(
            store: first.store, workspaceID: first.workspace.id, gate: UngatedTurns(),
            makeRunner: { session, _, store, environment, _ in first.runners.make(session: session, store: store, environment: environment) },
            installedAgents: { [.claudeCode] }, models: { _ in [] }, runnerExitGrace: .milliseconds(50)
        )
        try await second.start()

        let messages = try await first.store.messages(sessionID: first.session.id)
        let row = try #require(messages.last)
        #expect(row.kind == .error)
        let exit = AgentExit.decode(row.payload)
        #expect(exit.summary == WorkspaceRuntime.restartedSentence, "the row says what happened")
        #expect(exit.title == "Turn stopped", "rather than reading as the agent's own failure")
        let session = try #require(try await first.store.session(id: first.session.id))
        #expect(session.state.isMidTurn == false, "and the chat stops claiming to be running")

        // Idempotent: a second start writes nothing, or every restart would add a row.
        let again = WorkspaceRuntime(
            store: first.store, workspaceID: first.workspace.id, gate: UngatedTurns(),
            makeRunner: { session, _, store, environment, _ in first.runners.make(session: session, store: store, environment: environment) },
            installedAgents: { [.claudeCode] }, models: { _ in [] }, runnerExitGrace: .milliseconds(50)
        )
        try await again.start()
        let afterSecondStart = try await first.store.messages(sessionID: first.session.id)
        #expect(afterSecondStart.count == messages.count)
        await second.shutdown()
        await again.shutdown()
    }

    @Test("a machine with an agent missing says which name it looked for and where")
    func missingAgentsAreNamed() async throws {
        let everything = AgentKind.allCases.filter(\.canRunWorkspaces)
        #expect(WorkspaceRuntime.missingAgentsNote(found: everything, path: "/usr/bin") == nil,
                "nothing to say when they all resolve")

        let note = try #require(WorkspaceRuntime.missingAgentsNote(
            found: everything.filter { $0 != .grok }, path: "/home/sprite/.local/bin:/usr/bin"))
        #expect(note.contains("grok"), "the name it looked for, not the label a person reads")
        #expect(note.contains("/home/sprite/.local/bin:/usr/bin"), "and where it looked")
    }

    @Test("a client can learn what a chat would start with before any chat exists")
    func composerDefaultsWithoutAChat() async throws {
        let fixture = try await fixture()
        let caller = Self.caller(Self.freek)

        // On the snapshot, so the first chat in a workspace is not started from a guess.
        guard case .workspace(let snapshot)? = await fixture.runtime.respond(to: CommandRequest(.workspace), as: caller).result else {
            Issue.record("no workspace"); return
        }
        #expect(snapshot.chats.count == 1)
        #expect(!snapshot.composerDefaults.agent.isEmpty)
        #expect(!snapshot.composerDefaults.model.isEmpty)

        // And the same values through `composer` with no chat, which carries the choices too.
        guard case .composer(let offered)? = await fixture.runtime.respond(to: CommandRequest(.composer(chatID: nil)), as: caller).result else {
            Issue.record("no composer"); return
        }
        #expect(offered.chatID == nil, "there is no chat to name")
        #expect(offered.controls == snapshot.composerDefaults, "one answer, two places to read it")
        #expect(offered.availableAgents.isEmpty == false)

        // A chat started on them is started on exactly what was offered, which is the property the
        // two clients were each guessing at.
        guard case .chat(let made)? = await fixture.runtime.respond(
            to: CommandRequest(.newChat(controls: snapshot.composerDefaults)), as: caller).result else {
            Issue.record("no chat"); return
        }
        guard case .composer(let settled)? = await fixture.runtime.respond(
            to: CommandRequest(.composer(chatID: made.id)), as: caller).result else {
            Issue.record("no composer"); return
        }
        #expect(settled.controls == snapshot.composerDefaults)
        await fixture.runtime.shutdown()
    }

    @Test("a machine that cannot reach runbloom.app says so on the workspace it serves")
    func reportingIsOnTheWorkspaceRecord() async throws {
        let fixture = try await fixture()
        let caller = Self.caller(Self.freek)
        guard case .workspace(let quiet)? = await fixture.runtime.respond(to: CommandRequest(.workspace), as: caller).result else {
            Issue.record("no workspace"); return
        }
        #expect(quiet.workspace.reporting == nil, "nothing to say is said with nothing")

        let lost = Date(timeIntervalSince1970: 1_700_000_000)
        await fixture.runtime.reportingChanged(ReportingRecord(unreachableSince: lost, shed: 2))
        guard case .workspace(let worried)? = await fixture.runtime.respond(to: CommandRequest(.workspace), as: caller).result else {
            Issue.record("no workspace"); return
        }
        #expect(worried.workspace.reporting?.unreachableSince == lost)
        #expect(worried.workspace.reporting?.shed == 2)

        await fixture.runtime.reportingChanged(nil)
        guard case .workspace(let calm)? = await fixture.runtime.respond(to: CommandRequest(.workspace), as: caller).result else {
            Issue.record("no workspace"); return
        }
        #expect(calm.workspace.reporting == nil, "and it goes away again when contact comes back")
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

    @Test("removing a blocked prompt lets the ones behind it try again")
    func cancellingABlockedPromptUnblocks() async throws {
        let gate = RemoteTestGate()
        gate.refusal.withLock { $0 = .blocked(DeliveryBlock(limit: "monthly_hours", message: "Out of hours.")) }
        let fixture = try await fixture(gate: gate)
        let chat = fixture.session.id.rawValue
        let first = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Blocked")), as: Self.caller(Self.freek))
        guard case .queued(let blockedID) = first.result else { Issue.record("Expected queued"); return }
        await waitUntil("the prompt was marked blocked") {
            (try? await fixture.store.pendingDeliveries(sessionID: fixture.session.id).first?.block) != nil
        }
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Behind it")), as: Self.caller(Self.freek))
        gate.refusal.withLock { $0 = nil }
        let cancelled = await fixture.runtime.respond(to: CommandRequest(.cancelQueued(chatID: chat, promptID: blockedID)), as: Self.caller(Self.freek))
        #expect(cancelled.error == nil)
        await waitUntil("the prompt behind it went") { fixture.runners.sent.withLock { $0 } == ["Behind it"] }
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

    @Test("a search finds this workspace's transcripts, with the matching words marked")
    func transcriptSearch() async throws {
        let fixture = try await fixture()
        _ = try await fixture.store.appendNext(sessionID: fixture.session.id, kind: .assistantText,
                                               payload: Data(#"{"text":"I will retry the queue twice"}"#.utf8))
        _ = try await fixture.store.appendNext(sessionID: fixture.session.id, kind: .assistantText,
                                               payload: Data(#"{"text":"Nothing to do with that word"}"#.utf8))

        let reply = await fixture.runtime.respond(to: CommandRequest(.transcriptSearch(query: "retry", limit: nil)),
                                                  as: Self.caller(Self.freek))
        guard case .search(let found) = reply.result else { Issue.record("No search result: \(String(describing: reply.error))"); return }
        #expect(found.total == 1)
        let match = try #require(found.matches.first)
        #expect(match.chatID == fixture.session.id.rawValue)
        #expect(match.excerpt.contains { $0.isMatch && $0.text.lowercased().contains("retry") })
        #expect(match.cursor > 0, "The cursor is the row's own id, so a client can open it")

        let empty = await fixture.runtime.respond(to: CommandRequest(.transcriptSearch(query: "   ", limit: nil)),
                                                  as: Self.caller(Self.freek))
        #expect(empty.error?.code == .invalidValue)
        await fixture.runtime.shutdown()
    }

    @Test("a failed setup's last lines travel with the workspace, and only a failed one's")
    func setupFailureNote() async throws {
        let fixture = try await fixture()
        var workspace = try #require(try await fixture.store.workspace(id: fixture.runtime.workspaceID))
        workspace.setupState = .failed
        workspace.setupLog = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\nThe setup script exited with status 4."
        let note = try #require(WorkspaceRuntime.failureNote(workspace))
        #expect(note.hasSuffix("The setup script exited with status 4."))
        #expect(note.contains("line 20"))
        #expect(!note.contains("line 1\n"), "Only the tail, so it can travel in every workspace record")

        workspace.setupState = .succeeded
        #expect(WorkspaceRuntime.failureNote(workspace) == nil)
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

    @Test("a stop that sends no event still ends the turn, with the queue paused as a stop leaves it")
    func aSilentStopSettles() async throws {
        let gate = RemoteTestGate()
        let fixture = try await fixture(gate: gate)
        fixture.runners.silentCancel.withLock { $0 = true }
        let chat = fixture.session.id.rawValue
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Long job")), as: Self.caller(Self.freek))
        await waitUntil("the turn is running") { fixture.runners.sent.withLock { $0 }.count == 1 }
        #expect(await fixture.runtime.activity().turnsRunning == 1)
        _ = await fixture.runtime.respond(to: CommandRequest(.stop(chatID: chat)), as: Self.caller(Self.freek))
        await waitUntil("the stopped turn came to rest") { await fixture.runtime.activity().turnsRunning == 0 }
        await waitUntil("its runbloom.app turn was ended") { !gate.ended.withLock { $0 }.isEmpty }
        await fixture.runtime.shutdown()
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

    @Test("a question in one chat does not count as waiting while another chat is working")
    func oneWaitingChatDoesNotReleaseAnother() async throws {
        let fixture = try await fixture()
        let other = try await fixture.store.upsert(Session(workspaceID: fixture.workspace.id, title: "Other"))
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "One")), as: Self.caller(Self.freek))
        await waitUntil("the first turn is running") { fixture.runners.sent.withLock { $0 }.count == 1 }
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: other.id.rawValue, text: "Two")), as: Self.caller(Self.freek))
        await waitUntil("the second turn is running") { fixture.runners.sent.withLock { $0 }.count == 2 }
        let ask = try #require(PermissionAsk.decode(payload: Data(PermissionAskTests.realAsk.utf8)))
        try await fixture.store.appendPermissionAsk(sessionID: fixture.session.id, ask: ask)
        let activity = await fixture.runtime.activity()
        #expect(activity.turnsRunning == 2)
        #expect(activity.questionWaitingSince == nil)
        await fixture.runtime.shutdown()
    }

    @Test("a long backlog is replayed in order, a page at a time, and each row once")
    func backlogIsReplayedInPages() async throws {
        let fixture = try await fixture()
        // More rows than one page, so the replay has to walk: it used to read the whole backlog
        // into one array before the stream answered, which is a machine's memory for a client's
        // reconnection.
        var ids: [Int64] = []
        for index in 1...450 {
            let row = try await fixture.store.appendNext(sessionID: fixture.session.id, kind: .assistantText,
                                                        payload: Data(#"{"text":"row \#(index)"}"#.utf8))
            ids.append(row.id)
        }
        let stream = try await fixture.runtime.openEvents(for: Self.caller(Self.freek), after: ids.first)
        var iterator = stream.makeAsyncIterator()
        var replayed: [Int64] = []
        while let event = await iterator.next() {
            if let cursor = event.cursor { replayed.append(cursor) }
            if replayed.count == ids.count - 1 { break }
        }
        #expect(replayed == Array(ids.dropFirst()), "Every row after the cursor, in order, once each")

        // And a row written after the stream opened arrives from the live side, not the replay.
        let fresh = try await fixture.store.appendNext(sessionID: fixture.session.id, kind: .assistantText,
                                                       payload: Data(#"{"text":"after"}"#.utf8))
        while let event = await iterator.next() {
            if let cursor = event.cursor {
                #expect(cursor == fresh.id)
                break
            }
        }
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
    /// Stops the way Claude Code does: the store says cancelled, and no event arrives.
    let silentCancel = Mutex(false)

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

    nonisolated func cancelNow() {
        guard owner.silentCancel.withLock({ $0 }) else {
            sink.yield(.result(AgentResult()))
            return
        }
        let store = store, id = sessionID
        Task { try? await store.update(sessionID: id) { $0.state = .cancelled } }
    }
    nonisolated func terminateNow() { terminated.withLock { $0 = true } }

    func answer(requestID: String, decision: PermissionDecision) async {
        try? await store.resolvePermissionAsk(id: requestID, decision: decision.storedName)
    }

    func finish() {
        sink.yield(.result(AgentResult()))
    }
}

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

    func fixture(
        gate: any RemoteTurnGate = UngatedTurns(),
        createCloudWorkspace: (@Sendable (CloudWorkspaceRequest) async -> CloudWorkspaceAnswer)? = nil,
        models: @escaping WorkspaceRuntime.ModelDiscovery = { _ in [] },
        settings: String? = nil,
        peers: WorkspacePeers? = nil,
        lookUpMember: @escaping @Sendable (String) async -> MemberLookup = { _ in .unknown },
        addressed: (@Sendable (AddressedReport) async -> Void)? = nil
    ) async throws -> Fixture {
        let store = try makeTestStore("remote-runtime")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let path = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let settings {
            try FileManager.default.createDirectory(atPath: path + "/.bloom", withIntermediateDirectories: true)
            try settings.write(toFile: path + "/.bloom/settings.toml", atomically: true, encoding: .utf8)
        }
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Queue retries", branch: "queue-retries", path: path, baseBranch: "main"))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let runners = RemoteTestRunners()
        let runtime = WorkspaceRuntime(
            store: store, workspaceID: workspace.id, gate: gate,
            makeRunner: { session, _, store, environment, _ in runners.make(session: session, store: store, environment: environment) },
            installedAgents: { [.claudeCode, .codex] }, models: models, runnerExitGrace: .milliseconds(50),
            lookUpMember: lookUpMember, addressed: addressed,
            createCloudWorkspace: createCloudWorkspace, peers: peers
        )
        try await runtime.start()
        return Fixture(store: store, workspace: workspace, session: session, runtime: runtime, runners: runners)
    }

    static func caller(_ author: MessageAuthor, abilities: Set<String> = ["view", "prompt", "terminal", "files"]) -> RemoteCaller {
        RemoteCaller(author: author, abilities: abilities, sessionToken: "token-for-\(author.userID)")
    }

    /// **Refused rather than stored when the machine cannot vouch for the id.** Writing a message
    /// addressed to somebody nobody has confirmed exists is addressing the wrong person, done
    /// convincingly, which is the failure mentions exist to prevent.
    @Test("a message to a person is refused while this machine does not know who the team is")
    func addressingSomebodyUnknown() async throws {
        let fixture = try await fixture()
        let audience = AudienceRecord(kind: "person", userID: "user-seb", mention: "@sebdd")

        await #expect(throws: RemoteFailure.self) {
            _ = try await fixture.runtime.send(fixture.session.id.rawValue, text: "@sebdd yours",
                                               audience: audience, as: Self.caller(.init(userID: "u1", name: "Freek")))
        }
        // Nothing was written, so nothing can be read back as though it had been sent.
        let messages = try await fixture.store.messages(sessionID: fixture.session.id)
        #expect(messages.isEmpty)
        await fixture.runtime.shutdown()
    }

    /// M2 in the review of 19 September 2026: the report is what causes mail, and runbloom.app can
    /// only check who wrote the message against the token the words arrived on.
    @Test("a message to a person is reported with the sender's own token, and forgets it once sent")
    func addressingCarriesTheSendersToken() async throws {
        let reports = Mutex<[AddressedReport]>([])
        let fixture = try await fixture(
            lookUpMember: { .member(WorkspaceMember(userID: $0, name: "Seb", handle: "sebdd")) },
            addressed: { report in reports.withLock { $0.append(report) } }
        )
        let audience = AudienceRecord(kind: "person", userID: "user-seb", mention: "@sebdd")
        _ = try await fixture.runtime.send(fixture.session.id.rawValue, text: "@sebdd yours",
                                           audience: audience, as: Self.caller(.init(userID: "u1", name: "Freek")))

        let sent = try #require(reports.withLock { $0.first })
        #expect(sent.senderToken == "token-for-u1")
        #expect(sent.body["sender_token"]?.stringValue == "token-for-u1")
        let stored = try #require(try await fixture.store.unsentAddressedReports().first)
        #expect(stored.senderToken == "token-for-u1", "kept, so a retry after a restart can still prove it")
        try await fixture.store.markAddressedReported(id: stored.id)
        #expect(try await fixture.store.unsentAddressedReports().isEmpty)
        await fixture.runtime.shutdown()
    }

    /// M4 in the review of 19 September 2026: a search that reads for ten seconds used to hold the
    /// actor, and with it every command, stop and revoke, for all ten.
    @Test("disk work runs beside the runtime, one search per person and a few at a time")
    func diskWorkDoesNotHoldTheRuntime() async throws {
        let fixture = try await fixture()
        let release = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        let caller = Self.caller(.init(userID: "u1", name: "Freek"))
        let search = Task {
            try await fixture.runtime.blocking(search: caller) {
                started.withLock { $0 = true }
                release.wait()
                return 1
            }
        }
        await waitUntil("the search is running") { started.withLock { $0 } }
        // The runtime still answers while the search is reading.
        let reply = await fixture.runtime.respond(to: CommandRequest(.workspace), as: caller)
        #expect(reply.error == nil)
        // The same person's second search is turned away rather than queued behind the first.
        await #expect(throws: RemoteFailure.self) {
            _ = try await fixture.runtime.blocking(search: caller) { 2 }
        }
        // Somebody else's is not.
        let other = try await fixture.runtime.blocking(search: Self.caller(.init(userID: "u2", name: "Seb"))) { 3 }
        #expect(other == 3)
        release.signal()
        #expect(try await search.value == 1)
        // Finished, so the first person may search again.
        #expect(try await fixture.runtime.blocking(search: caller) { 4 } == 4)
        await fixture.runtime.shutdown()
    }

    @Test("a report written with no token says nothing about one")
    func aReportWithNoTokenLeavesItOut() {
        let report = AddressedReport(sessionID: SessionID("s"), userID: "u", connected: false, sentAt: Date(), from: .guest)
        #expect(report.body["sender_token"] == nil)
    }

    /// What the machine found under a step travels in the summary, so runbloom.app decides on an
    /// observation rather than on the age of a field.
    @Test("the summary carries what is alive under the setup step, and loses it when setup ends")
    func summaryCarriesSetupLiveness() async throws {
        let fixture = try await fixture()
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(try await Self.summary(of: fixture.runtime).setup.liveness == nil,
                "a machine with nothing to say says nothing, which is not a stall")

        await fixture.runtime.setupStepStarted("setup")
        await fixture.runtime.setupLivenessChanged(.init(verdict: "nothing_alive", running: 0, defunct: 1, at: at))
        let stalled = try await Self.summary(of: fixture.runtime).setup

        #expect(stalled.liveness?.verdict == "nothing_alive")
        #expect(stalled.liveness?.defunct == 1)
        #expect(stalled.step == "setup")

        // A verdict about a step that has ended would be read as one about whatever runs next.
        await fixture.runtime.setupFinished(succeeded: true)
        #expect(try await Self.summary(of: fixture.runtime).setup.liveness == nil)
        await fixture.runtime.shutdown()
    }

    private static func summary(of runtime: WorkspaceRuntime) async throws -> RemoteSummary {
        try await runtime.summary(
            revision: 1, observedAt: Date(), version: "test", awake: true, leaseUntil: nil,
            diff: .init(files: 0, additions: 0, deletions: 0), pullRequest: nil, atStake: nil
        )
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

    /// L2 in the review of 19 September 2026: whole requests kept for ever, uploads included.
    @Test("the journal keeps a hash of the command for a day, and never a mark_read")
    func theJournalKeepsLittleAndNotForLong() async throws {
        let fixture = try await fixture()
        let rename = CommandRequest(.renameChat(chatID: fixture.session.id.rawValue, title: "Secret plans"), commandID: "hashed")
        _ = await fixture.runtime.respond(to: rename, as: Self.caller(Self.freek))
        let kept = try #require(try await fixture.store.setting("remote.command.\(Self.freek.userID).hashed"))
        #expect(!kept.contains("Secret plans"), "the request's words are not kept, only its hash")
        #expect(kept.contains("request_hash"))

        let read = CommandRequest(.markRead(chatID: fixture.session.id.rawValue, seq: 0), commandID: "read")
        _ = await fixture.runtime.respond(to: read, as: Self.caller(Self.seb, abilities: ["view"]))
        #expect(try await fixture.store.setting("remote.command.\(Self.seb.userID).read") == nil)

        let stale = #"{"recorded_at":"2026-01-01T00:00:00.000Z","request_hash":"x"}"#
        try await fixture.store.setSetting("remote.command.\(Self.freek.userID).old", stale)
        await fixture.runtime.pruneJournal(now: Date().addingTimeInterval(2 * 60 * 60))
        #expect(try await fixture.store.setting("remote.command.\(Self.freek.userID).old") == nil)
        #expect(try await fixture.store.setting("remote.command.\(Self.freek.userID).hashed") != nil, "a fresh one stays")
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

    /// The tier the Mac's `CodexSpeed` reads, carried rather than thrown away, so a web client can
    /// offer fast mode on a Codex model without a probe of its own.
    @Test("a Codex model carries its fast tier onto the wire, and one without a tier carries none")
    func codexModelsCarryTheirFastTier() {
        let fast = ModelRecord(agent: "codex", codex: CodexModel(id: "gpt-5.5", displayName: "GPT-5.5", fastServiceTier: "priority"))
        let plain = ModelRecord(agent: "codex", codex: CodexModel(id: "gpt-5.5-mini", displayName: "GPT-5.5 mini"))

        #expect(fast.fastTier == "priority")
        #expect(plain.fastTier == nil, "absent is what no fast mode looks like")
    }

    /// runbloom.app decides who is asking from the turn, so the machine sends the turn it is really
    /// running and never a guess. A chat with no person's turn in it is refused before anything is
    /// sent.
    @Test("a Cloud workspace is asked for under the running turn, and refused from a chat with none")
    func cloudWorkspacesAreAskedForUnderTheTurn() async throws {
        let gate = RemoteTestGate()
        let asked = Mutex<[CloudWorkspaceRequest]>([])
        let fixture = try await fixture(gate: gate, createCloudWorkspace: { request in
            asked.withLock { $0.append(request) }
            return .created(CloudWorkspaceCreated(id: "01k5new", name: request.order.name, state: "setting_up", url: "https://runbloom.app/w/01k5new"))
        })
        let order = CloudWorkspaceOrder(name: "Spike")

        guard case .refused(let between) = await fixture.runtime.startCloudWorkspace(order, sessionID: fixture.session.id) else {
            Issue.record("A chat with no turn running asked runbloom.app anyway"); return
        }
        #expect(between.contains("a person is prompting"))
        #expect(asked.withLock { $0 }.isEmpty)

        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Make a spike")),
                                          as: Self.caller(Self.freek))
        await waitUntil("the turn is running") { fixture.runners.sent.withLock { $0 } == ["Make a spike"] }
        let answer = await fixture.runtime.startCloudWorkspace(order, sessionID: fixture.session.id)

        guard case .created = answer else { Issue.record("Expected created, got \(answer)"); return }
        let turnID = try #require(gate.registered.withLock { $0 }.first?.turnID)
        let request = try #require(asked.withLock { $0 }.first)
        #expect(request.turnID == turnID, "runbloom.app's own id for the turn, which is how it knows who asked")
        #expect(request.idempotencyKey == CloudWorkspaceRequest.idempotencyKey(turnID: turnID, name: "Spike"))
        await fixture.runners.finishTurn()
        await fixture.runtime.shutdown()
    }

    /// The opening is queued once, under runbloom.app's turn and the person who asked, on the
    /// creating chat's agent laid over this machine's defaults; a boot that finds the kept copy
    /// again after queueing it does not queue it twice.
    @Test("a kept opening becomes one queued prompt in a new chat, under its turn and its person")
    func anOpeningIsQueuedOnce() async throws {
        let fixture = try await fixture()
        // Held behind setup, as every prompt is, which is also what keeps it in the queue to look at.
        await fixture.runtime.setupStepStarted("setup")
        let opening = RemoteOpening(turnID: "01jopen", prompt: "Try the retry queue", controls: ["agent": .string("codex")],
                                    promptedBy: .init(userID: Self.freek.userID, name: "Freek", handle: "freek"))
        try await fixture.runtime.storeOpening(opening)

        let chat = try #require(try await fixture.runtime.deliverStoredOpening())
        let session = try #require(try await fixture.store.session(id: chat))
        #expect(session.agentKind == .codex, "the creating chat's agent, over this machine's Claude default")
        let queued = try await fixture.store.pendingDeliveries(sessionID: chat)
        #expect(queued.map(\.body) == ["Try the retry queue"])
        #expect(queued.first?.remoteTurnID == "01jopen", "runbloom.app's turn, which is what start hands a key out for")
        #expect(queued.first?.author?.userID == Self.freek.userID)

        #expect(try await fixture.runtime.deliverStoredOpening() == nil, "nothing is kept once it is queued")
        #expect(try await fixture.runtime.hasDeliveredOpening(turnID: "01jopen"))
        // Fetched again because its acknowledgement was lost: recognised by its turn, whether or not
        // its prompt is still waiting, and never queued into a second chat.
        try await fixture.runtime.storeOpening(opening)
        #expect(try await fixture.runtime.deliverStoredOpening() == nil)
        #expect(try await fixture.store.pendingDeliveries(sessionID: chat).count == 1)
        #expect(try await fixture.store.sessions(workspaceID: fixture.workspace.id).count == 2, "no second chat")
        await fixture.runtime.shutdown()
    }

    @Test("a prompt is sent with the creating chat's agent and model, never ones the agent chose")
    func aPromptCarriesTheCreatingChat() async throws {
        let gate = RemoteTestGate()
        let asked = Mutex<[CloudWorkspaceRequest]>([])
        let fixture = try await fixture(gate: gate, createCloudWorkspace: { request in
            asked.withLock { $0.append(request) }
            return .created(CloudWorkspaceCreated(id: "01k5new", name: request.order.name, state: "setting_up", url: "https://x"))
        })
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Make a spike")),
                                          as: Self.caller(Self.freek))
        await waitUntil("the turn is running") { fixture.runners.sent.withLock { $0 } == ["Make a spike"] }

        _ = await fixture.runtime.startCloudWorkspace(CloudWorkspaceOrder(name: "Spike", prompt: "Try it"), sessionID: fixture.session.id)
        let request = try #require(asked.withLock { $0 }.first)
        #expect(request.agent == fixture.session.agentKind.wireName)
        #expect(request.model == fixture.session.model)
        await fixture.runners.finishTurn()
        await fixture.runtime.shutdown()
    }

    /// A message an agent sent through a person's token is still the person's, and says an agent
    /// wrote it; a label this machine cannot draw is refused before anything is written.
    @Test("via reaches the transcript row, and a kind the machine does not know refuses the send")
    func viaIsKeptOnTheRow() async throws {
        let fixture = try await fixture()
        let chat = fixture.session.id.rawValue
        let long = String(repeating: "x", count: 500)
        let reply = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Rebase and push",
            via: ViaRecord(workspace: "Queue retries", chat: long))), as: Self.caller(Self.freek))
        guard case .queued = reply.result else { Issue.record("Not queued: \(String(describing: reply.error))"); return }
        await waitUntil("the prompt becomes a row", within: .seconds(30)) {
            ((try? await fixture.store.messages(sessionID: fixture.session.id)) ?? []).contains { $0.kind == .user }
        }
        let row = try #require(try await fixture.store.messages(sessionID: fixture.session.id).first { $0.kind == .user })
        #expect(row.author?.userID == Self.freek.userID, "still the person's message")
        #expect(row.via?.workspace == "Queue retries")
        #expect(row.via?.chat?.count == 200, "a label cannot carry a paragraph into somebody's transcript")
        #expect(row.record.via?.kind == "agent")

        let refused = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Something else",
            via: ViaRecord(kind: "robot"))), as: Self.caller(Self.freek))
        #expect(refused.error?.code == .invalidValue)
        #expect(try await fixture.store.messages(sessionID: fixture.session.id).filter { $0.kind == .user }.count == 1)
        await fixture.runners.finishTurn()
        await fixture.runtime.shutdown()
    }

    /// Claude Code's list, as a machine signed out of any account reads it.
    static let claudeList: WorkspaceRuntime.ModelDiscovery = { _ in [
        ModelRecord(agent: "claude", id: "opus[1m]", label: "Opus 5 with 1M context", efforts: ["low", "medium", "high"],
                    defaultEffort: nil, isDefault: true),
        ModelRecord(agent: "claude", id: "sonnet", label: "Sonnet 5", efforts: ["low", "medium", "high"], defaultEffort: nil, isDefault: false),
    ] }

    /// **A picker's current model is in its own menu.** The real machine showed the built-in default
    /// `opus` beside a list that has `opus[1m]` and no `opus`, the same class of mistake as a client
    /// reading `name` where the wire says `label`: every fake agreed with itself.
    @Test("with nothing pinned, the default model is one the list offers")
    func theDefaultIsInTheList() async throws {
        let fixture = try await fixture(models: Self.claudeList)
        let reply = await fixture.runtime.respond(to: CommandRequest(.composer(chatID: nil)), as: Self.caller(Self.freek))
        guard case .composer(let composer) = reply.result else { Issue.record("No composer"); return }
        let offered = composer.models.filter { $0.agent == composer.controls.agent }.map(\.id)
        #expect(offered.contains(composer.controls.model), "\(composer.controls.model) is not in \(offered)")
        #expect(composer.controls.model == "opus[1m]", "the one the list marks as its default")
        await fixture.runtime.shutdown()
    }

    @Test("a model the project pinned is kept, even one the list does not offer")
    func aPinnedModelIsKept() async throws {
        let fixture = try await fixture(models: Self.claudeList, settings: "[models]\ndefault = \"opus\"\n")
        let reply = await fixture.runtime.respond(to: CommandRequest(.composer(chatID: nil)), as: Self.caller(Self.freek))
        guard case .composer(let composer) = reply.result else { Issue.record("No composer"); return }
        #expect(composer.controls.model == "opus", "the project asked for it; a client draws it as its own row")
        await fixture.runtime.shutdown()
    }

    /// runbloom.app decides who is asking from the turn, so the machine sends the one really
    /// running, and the other machine is told which workspace and chat the agent was in, by name.
    @Test("a message to another workspace goes under the running turn, with this workspace's name and chat")
    func messagesToPeersCarryTheTurnAndTheLabel() async throws {
        let gate = RemoteTestGate()
        let sent = Mutex<[PeerMessage]>([])
        let peers = WorkspacePeers(list: { _ in .listed([]) }, say: { message in
            sent.withLock { $0.append(message) }
            return .sent(workspace: "Other", chat: "Chat", queued: false)
        })
        let fixture = try await fixture(gate: gate, peers: peers)

        guard case .refused = await fixture.runtime.sayToPeer(workspace: "Other", chat: nil, text: "Hi", sessionID: fixture.session.id) else {
            Issue.record("A chat with no turn running reached another workspace"); return
        }
        #expect(sent.withLock { $0 }.isEmpty)

        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Tell the other one")),
                                          as: Self.caller(Self.freek))
        await waitUntil("the turn is running") { fixture.runners.sent.withLock { $0 } == ["Tell the other one"] }
        _ = await fixture.runtime.sayToPeer(workspace: "Other", chat: nil, text: "Rebase on main", sessionID: fixture.session.id)

        let message = try #require(sent.withLock { $0 }.first)
        #expect(message.turnID == gate.registered.withLock { $0 }.first?.turnID)
        #expect(message.via.workspace == "Queue retries")
        #expect(message.via.chat == fixture.session.title)
        #expect(message.text == "Rebase on main")
        await fixture.runners.finishTurn()
        await fixture.runtime.shutdown()
    }

    @Test("stop_setup reaches the machine's setup, and with nothing running says there is nothing to stop")
    func stoppingSetup() async throws {
        let fixture = try await fixture()
        let idle = await fixture.runtime.respond(to: CommandRequest(.stopSetup), as: Self.caller(Self.freek))
        #expect(idle.error?.code == .conflict)

        let asked = Mutex<[String]>([])
        await fixture.runtime.setSetupStopper { name in
            asked.withLock { $0.append(name) }
            return true
        }
        let stopped = await fixture.runtime.respond(to: CommandRequest(.stopSetup), as: Self.caller(Self.freek))
        #expect(stopped.result == .accepted)
        #expect(asked.withLock { $0 } == ["Freek"], "the setup is told who stopped it")
        await fixture.runtime.shutdown()
    }

    /// The Mac's gate decides, so a workspace whose pull request has not merged is refused in the
    /// Mac's own words, and moving the branch needs the ability to prompt as well as to write.
    @Test("continue_after_merge is refused without a merged pull request, and to a caller who cannot prompt")
    func continuingIsGated() async throws {
        let fixture = try await fixture()
        let refused = await fixture.runtime.respond(to: CommandRequest(.continueAfterMerge(chatID: nil)), as: Self.caller(Self.freek))
        #expect(refused.error?.code == .conflict)
        #expect(refused.error?.message == ContinuationRefusal.notMerged.sentence)

        let writer = Self.caller(Self.seb, abilities: ["view", "files"])
        let noPrompt = await fixture.runtime.respond(to: CommandRequest(.continueAfterMerge(chatID: nil)), as: writer)
        #expect(noPrompt.error?.code == .missingAbility)
        await fixture.runtime.shutdown()
    }

    /// **A slow setup that is going well must not read as a failed call.** The call answers once the
    /// run has started, and a second one while it runs is refused on the spot. The run itself is the
    /// machine's (`MachineSetup.rerunSetup`, tested with a real script on Linux); here it stands in.
    @Test("run_setup answers as soon as setup starts, and refuses a second while it runs")
    func runSetupAnswersAtOnce() async throws {
        let fixture = try await fixture()
        let release = AsyncStream<Void>.makeStream()
        let runtime = fixture.runtime
        await runtime.setSetupRerunner {
            await runtime.setupStepStarted("setup")
            for await _ in release.stream { break }
            await runtime.setupFinished(succeeded: true)
            return true
        }

        let first = await runtime.respond(to: CommandRequest(.runSetup), as: Self.caller(Self.freek))
        #expect(first.result == .accepted, "\(String(describing: first.error))")
        await waitUntil("setup has started") { await runtime.holdsPromptsForSetup }
        let second = await runtime.respond(to: CommandRequest(.runSetup), as: Self.caller(Self.freek))
        #expect(second.error?.code == .busy, "the first is still running")

        release.continuation.yield()
        await waitUntil("setup has finished") { await !runtime.holdsPromptsForSetup }
        await runtime.shutdown()
    }

    @Test("a runtime with nobody to ask says so rather than pretending")
    func cloudWorkspacesNeedRunbloom() async throws {
        let fixture = try await fixture()
        guard case .refused(let sentence) = await fixture.runtime.startCloudWorkspace(CloudWorkspaceOrder(name: "Spike"),
                                                                                      sessionID: fixture.session.id) else {
            Issue.record("Created a workspace with nobody to ask"); return
        }
        #expect(sentence.contains("not connected to runbloom.app"))
        await fixture.runtime.shutdown()
    }

    /// **Asked for, not pushed**, so what has to hold is that the answer is the file as it is now:
    /// somebody edits it in the workspace and opens the menu again.
    @Test("quick_prompts reads the checkout on every call, and a viewer may ask")
    func quickPromptsFollowTheFile() async throws {
        let fixture = try await fixture()
        let viewer = Self.caller(Self.seb, abilities: ["view"])
        let file = (fixture.workspace.path as NSString).appendingPathComponent(".bloom/settings.toml")
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        func names() async -> [String]? {
            let reply = await fixture.runtime.respond(to: CommandRequest(.quickPrompts), as: viewer)
            guard case .quickPrompts(let prompts, _) = reply.result else { return nil }
            return prompts.map(\.name)
        }

        #expect(await names() == [], "no settings file is an empty menu, not an error")
        try "[[quick_prompts]]\nname = \"Tests\"\nprompt = \"Run the tests.\"\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(await names() == ["Tests"])
        try "[[quick_prompts]]\nname = \"Lint\"\nprompt = \"Run the linter.\"\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(await names() == ["Lint"])
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
        gate.refusal.withLock { $0 = .blocked(DeliveryBlock(limit: "concurrent_machines", message: "Your team already has 20 Bloom Cloud workspaces running. Close one to open this.")) }
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

    /// A client that did not close the chat learns it has gone from the last event about it, rather
    /// than keeping it in its strip until the next full read and being told "closed" on a send.
    @Test("closing a chat publishes a last chat event that says it is closed")
    func closingAChatSaysSo() async throws {
        let fixture = try await fixture()
        let stream = try await fixture.runtime.openEvents(for: Self.caller(Self.freek), after: nil)
        // Read beside the test rather than in it, so an event that never comes is a failure that
        // says what did come, not a suite that waits for ever: this hung the Linux job for thirty
        // minutes the first time, with nothing in the log to say why.
        let chats = Mutex<[ChatRecord]>([])
        let reader = Task {
            for await event in stream {
                if case .chat(let chat) = event { chats.withLock { $0.append(chat) } }
            }
        }
        let reply = await fixture.runtime.respond(to: CommandRequest(.closeChat(chatID: fixture.session.id.rawValue)), as: Self.caller(Self.seb))
        #expect(reply.result == .accepted)
        // A cap on "never" rather than a measurement, well under the suite's own limit.
        await waitUntil("a chat event saying the chat is closed", within: .seconds(30)) {
            chats.withLock { $0 }.contains { $0.id == fixture.session.id.rawValue && $0.closedAt != nil }
        }
        let seen = chats.withLock { $0 }
        #expect(seen.contains { $0.closedAt != nil }, "chat events seen: \(seen.map { "\($0.id) \($0.state) closed=\($0.closedAt != nil)" })")
        reader.cancel()
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

/// The `mac_message` events one stream received, read beside the test.
final class MacMessages: Sendable {
    final class Seen: Sendable {
        let records = Mutex<[MacMessageRecord]>([])
    }

    let seen = Seen()
    let reader: Task<Void, Never>

    init(_ stream: AsyncStream<WorkspaceEvent>) {
        let seen = self.seen
        reader = Task {
            for await event in stream { if case .macMessage(let record) = event { seen.records.withLock { $0.append(record) } } }
        }
    }
}

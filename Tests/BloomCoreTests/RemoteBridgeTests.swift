import BloomProtocol
import Foundation
import Synchronization
import Testing
@testable import BloomCore

/// The agent bridge inside a Cloud workspace, driven through its tool handlers against a runtime
/// whose agents are stand-ins, so what is asserted is where each message ends up in the queue.
@Suite("Cloud workspace bridge", .scratchDirectory, .tags(.persistence))
struct RemoteBridgeTests {
    struct Fixture {
        let store: Store
        let workspace: Workspace
        let orchestrator: Session
        let runtime: WorkspaceRuntime
        let agents: CrewRunners

        func identity(of session: Session) -> BridgeIdentity {
            BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .workspace)
        }

        func call(_ tool: String, _ arguments: [String: String] = [:], as session: Session) async -> BridgeToolResult {
            guard let handler = runtime.bridgeToolbox().handler(named: tool, for: .workspace) else {
                return .failure("\(tool) is not offered")
            }
            let request = MCPRequest(id: .integer(1), method: tool, params: .object(arguments.mapValues { .string($0) }))
            return await handler.call(request, as: identity(of: session), store: store)
        }

        func member(_ name: String) async throws -> Session {
            try #require(try await store.crew(of: orchestrator.id).first { $0.title == name })
        }
    }

    func fixture(bridgeSocketPath: String? = nil) async throws -> Fixture {
        let store = try makeTestStore("remote-bridge")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let path = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Crew", branch: "crew", path: path, baseBranch: "main"))
        let orchestrator = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let agents = CrewRunners()
        let runtime = WorkspaceRuntime(
            store: store, workspaceID: workspace.id,
            makeRunner: { session, _, store, environment, bridge in
                agents.make(session: session, store: store, environment: environment, bridge: bridge)
            },
            installedAgents: { [.claudeCode, .codex] }, models: { _ in [] }, runnerExitGrace: .milliseconds(50),
            bridgeSocketPath: bridgeSocketPath, bridgeShimPath: "/usr/local/bin/bloom-bridge"
        )
        try await runtime.start()
        return Fixture(store: store, workspace: workspace, orchestrator: orchestrator, runtime: runtime, agents: agents)
    }

    /// **The rule the whole mentions feature rests on.** `chat_read` is the only way an agent can
    /// read a transcript, so it is the only place a message addressed to a person could leak, and a
    /// leak here is the feature not existing.
    @Test("an agent reading a chat is not shown a message addressed to a person")
    func chatReadHidesMessagesToPeople() async throws {
        let fixture = try await fixture()
        let payload = { (text: String) in Data(JSONValue.object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .array([
                .object(["type": .string("text"), "text": .string(text)]),
            ])]),
        ]).compactJSON.utf8) }
        _ = try await fixture.store.appendNext(sessionID: fixture.orchestrator.id, kind: .user,
                                               payload: payload("for the agent"))
        _ = try await fixture.store.appendNext(
            sessionID: fixture.orchestrator.id, kind: .user, payload: payload("@sebdd this bit is yours"),
            audience: MessageAudience(kind: .person, userID: "user-seb", mention: "@sebdd")
        )
        // **The message after the addressed one, with no audience at all.** This is the shape the
        // feature is actually about: the address stuck for one message, the next one went to the
        // agent as normal, and the agent still never saw the one in between.
        _ = try await fixture.store.appendNext(sessionID: fixture.orchestrator.id, kind: .user,
                                               payload: payload("carry on"))

        let toolbox = fixture.runtime.bridgeToolbox()
        let handler = try #require(toolbox.handler(named: "chat_read", for: .workspace))
        let identity = BridgeIdentity(sessionID: fixture.orchestrator.id, workspaceID: fixture.workspace.id, role: .workspace)
        let answer = await handler.call(
            MCPRequest(id: .integer(1), method: "chat_read",
                       params: .object(["chat": .string(fixture.orchestrator.id.rawValue)])),
            as: identity, store: fixture.store
        )

        // **The count is part of the same promise.** An agent told there are three messages that
        // can only read two has been told a private one exists, which is the fact being kept.
        let listing = try #require(toolbox.handler(named: "chat_list", for: .workspace))
        let chats = await listing.call(MCPRequest(id: .integer(2), method: "chat_list"), as: identity, store: fixture.store)
        #expect(chats.text.contains("\"messages\" : 2"), "two of the three rows are the agent's: \(chats.text)")

        #expect(answer.text.contains("for the agent"))
        #expect(answer.text.contains("carry on"))
        #expect(!answer.text.contains("this bit is yours"))
        #expect(!answer.text.contains("@sebdd"))
        // And nothing says a message was left out: a marker invites the agent to ask what it missed.
        #expect(!answer.text.lowercased().contains("hidden"))
        await fixture.runtime.shutdown()
    }

    /// The whole of it end to end: the agent shows a picture, the chat gets a row naming a copy, and
    /// a client fetches that copy through `download`, the same door and the same token as any file.
    @Test("media_show writes a media row a client can download the picture from")
    func mediaShowReachesAClient() async throws {
        let fixture = try await fixture()
        let shot = TestScratch.unique("shot") + ".png"
        try MachineMediaShowTests.png.write(to: URL(filePath: shot))

        let answer = await fixture.call("media_show", ["path": shot, "caption": "After the fix"], as: fixture.orchestrator)
        #expect(!answer.isError, "\(answer.text)")

        let row = try #require(try await fixture.store.messages(sessionID: fixture.orchestrator.id).last)
        #expect(row.kind == .media)
        let media = try JSONDecoder().decode(SharedMedia.self, from: row.payload)
        #expect(media.caption == "After the fix")
        #expect(media.mime == "image/png")

        let caller = RemoteCaller(author: MessageAuthor(userID: "u1", name: "Freek"), abilities: ["view"], sessionToken: "t")
        let reply = await fixture.runtime.respond(to: CommandRequest(.download(path: media.path)), as: caller)
        guard case .download(let file) = reply.result else { Issue.record("No download: \(String(describing: reply.error))"); return }
        #expect(file.data == MachineMediaShowTests.png)
        await fixture.runtime.shutdown()
    }

    /// **Advice to a dead end** is what the agent Freek was testing with found: `agent_start` told it
    /// to use `workspace_start`, and three reading tools to pass "an id from workspace_list", on a
    /// machine that has neither. Every name a listing mentions has to be one the same listing offers.
    @Test("no tool on a machine names a tool the machine does not offer")
    func noDeadEnds() async throws {
        let fixture = try await fixture()
        let tools = fixture.runtime.bridgeToolbox().tools(for: .workspace)
        let offered = Set(tools.map(\.name))
        for tool in tools {
            let text = tool.description + String(describing: tool.inputSchema)
            // Whole names, not substrings: `workspace_start` is inside `cloud_workspace_start`.
            let words = try NSRegularExpression(pattern: "[a-z]+(?:_[a-z]+)+")
                .matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            let named = Self.everyToolName.intersection(words)
            #expect(named.isSubset(of: offered), "\(tool.name) names \(named.subtracting(offered).sorted())")
        }
        // And the arguments the dead ends came with are gone, not only the words.
        for name in ["chat_list", "chat_read", "workspace_diff"] {
            let schema = try #require(tools.first { $0.name == name }?.inputSchema)
            #expect(!String(describing: schema).contains("\"workspace\""), "\(name) still takes a workspace")
        }
        await fixture.runtime.shutdown()
    }

    /// Every bridge tool on either side. The Mac's own come from `AppModel.bridgeToolbox()`, which
    /// the core cannot build, so they are named here; the core's are read from the toolbox.
    /// `reveal` is left out because it is also a word.
    static let everyToolName: Set<String> = Set(BridgeToolbox.standard.handlers.map(\.tool.name)).union([
        "workspace_start", "workspace_say", "workspace_archive", "workspace_merge", "workspace_tabs",
        "workspace_tab_select", "pane_open", "pane_split", "pane_close", "pane_rename", "pane_list",
        "browser_go", "browser_read", "browser_click", "browser_fill", "browser_press", "browser_screenshot",
        "browser_snapshot", "browser_text", "browser_console", "browser_network", "browser_reload",
        "browser_scroll", "browser_wait", "media_show", "terminal_start", "terminal_read", "terminal_write",
        "terminal_send_key", "agent_start", "agent_say", "agent_stop", "request_pane", "cloud_workspace_start",
    ])

    @Test("only the tools about this one workspace are offered, and only to agents working in it")
    func theToolList() async throws {
        let fixture = try await fixture()
        let toolbox = fixture.runtime.bridgeToolbox()
        // Pinned on purpose, so adding a tool to a machine is a decision somebody takes rather
        // than a thing that happens. `request_pane` was added on 18 September 2026 and is the only
        // one here that reaches out of the machine at all: it asks a client to open a browser pane
        // and cannot open one itself. See `RequestPaneTool`. `cloud_setup` is guidance and touches
        // nothing; see `CloudSetupGuide`.
        // `media_show` was added on 19 September 2026 and writes into this workspace only: a copy
        // in its scratch folder and a row in the chat that called it. See `MachineMediaShowTool`.
        // `cloud_workspace_start` was added the night before, and it too only asks: runbloom.app makes
        // the workspace, or refuses with a sentence naming the team switch. See
        // `CloudWorkspaceStartTool`.
        #expect(toolbox.tools(for: .workspace).map(\.name) == [
            "agent_list", "agent_say", "agent_start", "agent_stop", "chat_list", "chat_read",
            "cloud_setup", "cloud_workspace_start", "media_show", "request_pane", "whoami", "workspace_diff",
            "workspace_list", "workspace_say",
        ])
        #expect(toolbox.tools(for: .owner).isEmpty)
        // `pane_open` in particular: the machine can ask for a pane and cannot open one, and the
        // names say which is which.
        // `workspace_list` and `workspace_say` reach the team's other Bloom Cloud workspaces through
        // runbloom.app's tokens, added on 19 September 2026; see `WorkspacePeers`.
        for absent in ["workspace_start", "workspace_archive", "pane_open", "browser_go", "project_list"] {
            #expect(toolbox.handler(named: absent, for: .workspace) == nil, "\(absent) is not offered")
        }

        let elsewhere = BridgeIdentity(sessionID: fixture.orchestrator.id, workspaceID: WorkspaceID("another"), role: .workspace)
        let handler = try #require(toolbox.handler(named: "chat_list", for: .workspace))
        let refused = await handler.call(MCPRequest(id: .integer(1), method: "chat_list"), as: elsewhere, store: fixture.store)
        #expect(refused.isError)
        let started = await fixture.runtime.startCrewMember(CrewOrder(name: "tests", task: "Run them"),
                                                           parentID: fixture.orchestrator.id, workspaceID: WorkspaceID("another"))
        guard case .refused = started else { Issue.record("A crew member was started for another workspace"); return }
        await fixture.runtime.shutdown()
    }

    @Test("agent_start opens a crew chat on the parent's agent and its brief reaches that chat's agent")
    func startingAMember() async throws {
        let fixture = try await fixture()
        let result = await fixture.call("agent_start", ["name": "tests", "task": "Run the suite"], as: fixture.orchestrator)
        #expect(!result.isError, "\(result.text)")
        let member = try await fixture.member("tests")
        #expect(member.parentSessionID == fixture.orchestrator.id)
        #expect(member.agentKind == fixture.orchestrator.agentKind)
        #expect(member.permissionMode == fixture.orchestrator.permissionMode)
        await waitUntil("the brief reached the member") { fixture.agents.sent(to: member.id) == ["Run the suite"] }
        #expect(fixture.agents.sent(to: fixture.orchestrator.id).isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test("agent_say goes down to a named member and, from a member, up to its parent")
    func sayingBothWays() async throws {
        let fixture = try await fixture()
        _ = await fixture.call("agent_start", ["name": "tests", "task": "Run the suite"], as: fixture.orchestrator)
        let member = try await fixture.member("tests")
        await waitUntil("the brief reached the member") { fixture.agents.sent(to: member.id).count == 1 }

        let down = await fixture.call("agent_say", ["to": "tests", "message": "Lint as well"], as: fixture.orchestrator)
        #expect(!down.isError, "\(down.text)")
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.agents.sent(to: member.id).count == 1, "Nothing is injected into a running turn")
        await fixture.agents.finishTurn(of: member.id)
        await waitUntil("the message reached the member") { fixture.agents.sent(to: member.id).count == 2 }
        #expect(fixture.agents.sent(to: member.id).last?.contains("Lint as well") == true)
        #expect(fixture.agents.sent(to: fixture.orchestrator.id).isEmpty, "A turn with another waiting behind it does not report")

        let up = await fixture.call("agent_say", ["message": "Two tests fail"], as: member)
        #expect(!up.isError, "\(up.text)")
        await waitUntil("the message reached the parent") {
            fixture.agents.sent(to: fixture.orchestrator.id).contains { $0.contains("Two tests fail") }
        }
        await fixture.runtime.shutdown()
    }

    @Test("a member's turn coming to rest queues its report to the parent")
    func reportingToTheParent() async throws {
        let fixture = try await fixture()
        _ = await fixture.call("agent_start", ["name": "tests", "task": "Run the suite"], as: fixture.orchestrator)
        let member = try await fixture.member("tests")
        await waitUntil("the brief reached the member") { fixture.agents.sent(to: member.id).count == 1 }
        await fixture.agents.finishTurn(of: member.id, summary: "All green")
        let expected = Crew.stoppedSentence(name: "tests", lastMessage: "All green")
        await waitUntil("the report reached the parent") { fixture.agents.sent(to: fixture.orchestrator.id) == [expected] }
        await fixture.runtime.shutdown()
    }

    @Test("agent_stop closes the member's chat without reporting back to the parent that asked")
    func stoppingAMember() async throws {
        let fixture = try await fixture()
        _ = await fixture.call("agent_start", ["name": "tests", "task": "Run the suite"], as: fixture.orchestrator)
        let member = try await fixture.member("tests")
        await waitUntil("the brief reached the member") { fixture.agents.sent(to: member.id).count == 1 }

        let result = await fixture.call("agent_stop", ["name": "tests"], as: fixture.orchestrator)
        #expect(!result.isError, "\(result.text)")
        #expect(try await fixture.store.session(id: member.id)?.archivedAt != nil)
        #expect(try await fixture.store.crew(of: fixture.orchestrator.id).isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.agents.sent(to: fixture.orchestrator.id).isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test("a crew member cannot start a crew member of its own")
    func noNesting() async throws {
        let fixture = try await fixture()
        _ = await fixture.call("agent_start", ["name": "tests", "task": "Run the suite"], as: fixture.orchestrator)
        let member = try await fixture.member("tests")

        let result = await fixture.call("agent_start", ["name": "deeper", "task": "Help"], as: member)
        #expect(result.isError)
        let direct = await fixture.runtime.startCrewMember(CrewOrder(name: "deeper", task: "Help"),
                                                          parentID: member.id, workspaceID: fixture.workspace.id)
        #expect(direct == .refused(Crew.sentence(for: .notAnOrchestrator)))
        #expect(try await fixture.store.crew(inWorkspace: fixture.workspace.id).map(\.title) == ["tests"])
        await fixture.runtime.shutdown()
    }

    @Test("with a socket, each chat's agent is launched with its own bridge registration, retired when the chat closes")
    func registration() async throws {
        let socket = "/tmp/bloom-rb-\(UUID().uuidString.prefix(8)).sock"
        let fixture = try await fixture(bridgeSocketPath: socket)
        let server = try #require(await fixture.runtime.bridge)
        defer { try? FileManager.default.removeItem(atPath: server.configDirectory) }

        let caller = RemoteCaller(author: RemoteWorkspaceRuntimeTests.freek, abilities: ["view", "prompt"], sessionToken: "token")
        let chat = fixture.orchestrator.id.rawValue
        _ = await fixture.runtime.respond(to: CommandRequest(.send(chatID: chat, text: "Hello")), as: caller)
        await waitUntil("the agent was launched") { fixture.agents.handle(for: fixture.orchestrator.id) != nil }

        let handle = try #require(fixture.agents.handle(for: fixture.orchestrator.id))
        let config = try #require(handle.mcpConfigPath, "A Claude Code chat is told about the bridge through a config file")
        #expect(FileManager.default.fileExists(atPath: config))
        #expect(handle.attachment.socketPath == socket)
        #expect(server.registry.identity(forToken: handle.attachment.token)?.sessionID == fixture.orchestrator.id)

        let closed = await fixture.runtime.respond(to: CommandRequest(.closeChat(chatID: chat)), as: caller)
        #expect(closed.result == .accepted, "\(String(describing: closed.error))")
        #expect(server.registry.identity(forToken: handle.attachment.token) == nil)
        #expect(!FileManager.default.fileExists(atPath: config))
        await fixture.runtime.shutdown()
    }
}

/// One stand-in agent per chat, so a test can finish one chat's turn and read what each was sent.
final class CrewRunners: Sendable {
    private let perChat = Mutex<[SessionID: RemoteTestRunners]>([:])
    private let handles = Mutex<[SessionID: BridgeHandle]>([:])

    func make(session: Session, store: Store, environment: [String: String], bridge: BridgeHandle?) -> any SessionRunner {
        if let bridge { handles.withLock { $0[session.id] = bridge } }
        return runners(for: session.id).make(session: session, store: store, environment: environment)
    }

    func sent(to id: SessionID) -> [String] {
        runners(for: id).sent.withLock { $0 }
    }

    func handle(for id: SessionID) -> BridgeHandle? {
        handles.withLock { $0[id] }
    }

    func finishTurn(of id: SessionID, summary: String = "") async {
        await runners(for: id).current.withLock { $0 }?.finish(summary: summary)
    }

    private func runners(for id: SessionID) -> RemoteTestRunners {
        perChat.withLock { table in
            if let existing = table[id] { return existing }
            let fresh = RemoteTestRunners()
            table[id] = fresh
            return fresh
        }
    }
}

extension RemoteTestRunner {
    func finish(summary: String) {
        sink.yield(.result(AgentResult(summary: summary)))
    }
}

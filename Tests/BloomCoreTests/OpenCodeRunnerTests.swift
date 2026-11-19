import Testing
import Foundation
@testable import BloomCore

private func makeOpenCodeSession(
    _ store: Store,
    model: String = OpenCodeFixture.localModel,
    effort: String = "",
    permissionMode: PermissionMode = .auto,
    agentSessionID: String? = nil
) async throws -> Session {
    let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
    let workspace = try await store.upsert(Workspace(
        repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
    ))
    return try await store.upsert(Session(
        workspaceID: workspace.id,
        agentSessionID: agentSessionID,
        model: model,
        effort: effort,
        agentKind: .openCode,
        permissionMode: permissionMode
    ))
}

private func makeRunner(store: Store, session: Session, box: ProcessBox) -> OpenCodeRunner {
    OpenCodeRunner(
        workspacePath: "/tmp/w",
        session: session,
        store: store,
        // No test here announces a provider, so a refused model gives up at once.
        announcementWait: .milliseconds(10),
        makeClient: { configuration in
            OpenCodeClient(configuration: configuration, makeProcess: box.factory)
        }
    )
}

/// A server whose model has the given effort levels. `session/resume` names no session. A prompt
/// is never answered unless `endsTurns`, which ends every turn at once.
private func scriptedBox(efforts: [String] = [], endsTurns: Bool = false) -> ProcessBox {
    let box = ProcessBox()
    box.reply(to: "initialize", with: .object([:]))
    var created = OpenCodeFixture.configOptions(model: OpenCodeFixture.hostedModel).objectValue ?? [:]
    created["sessionId"] = .string("ses_1")
    box.reply(to: "session/new", with: .object(created))
    box.reply(to: "session/resume", with: OpenCodeFixture.configOptions(model: OpenCodeFixture.localModel))
    box.reply(to: "session/set_config_option", with: OpenCodeFixture.configOptions(
        model: OpenCodeFixture.localModel, efforts: efforts
    ))
    if endsTurns {
        box.reply(to: "session/prompt", with: .object(["stopReason": .string("end_turn")]))
    } else {
        box.ignore("session/prompt")
    }
    return box
}

private func configOptionsSent(_ box: ProcessBox) -> [(id: String, value: String)] {
    box.process.stdin.compactMap(JSONValue.parse)
        .filter { $0["method"]?.stringValue == "session/set_config_option" }
        .map { ($0["params"]?["configId"]?.stringValue ?? "", $0["params"]?["value"]?.stringValue ?? "") }
}

private func eventually(
    _ description: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async {
    await waitUntil(Comment(rawValue: description), within: .seconds(2), sourceLocation: sourceLocation, condition)
}

@Suite(.scratchDirectory)
struct OpenCodeRunnerTests {
    @Test("a first send opens a session, stores its id and selects the composer's model")
    func firstSendOpensASession() async throws {
        let store = try makeTestStore("opencode-first-send")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("hello")
        await eventually("session id stored") {
            (try? await store.session(id: session.id)?.agentSessionID) == "ses_1"
        }
        #expect(box.process.sentMethods.contains("session/new"))
        #expect(box.process.sentMethods.contains("session/prompt"))
        let selected = configOptionsSent(box)
        #expect(selected.map(\.id) == ["model"])
        #expect(selected.first?.value == OpenCodeFixture.localModel)
        let rows = try await store.messages(sessionID: session.id)
        #expect(rows.contains { $0.kind == .user })
    }

    @Test("the permission mode reaches the process as injected config, not as a session parameter")
    func permissionModeIsALaunchSetting() async throws {
        let store = try makeTestStore("opencode-permission-launch")
        let session = try await makeOpenCodeSession(store, permissionMode: .acceptEdits)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("hello")
        let content = try #require(box.process.launch.environment["OPENCODE_CONFIG_CONTENT"])
        let rules = JSONValue.parse(Data(content.utf8))?["permission"]?.objectValue
        #expect(rules?.keys.sorted() == ["shell"])
    }

    @Test("a stored session id is resumed, and stays the id although the reply names none")
    func resumeUsesTheStoredID() async throws {
        let store = try makeTestStore("opencode-resume")
        let session = try await makeOpenCodeSession(store, agentSessionID: "ses_stored")
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("again")
        #expect(box.process.sentMethods.contains("session/resume"))
        #expect(!box.process.sentMethods.contains("session/new"))
        let prompt = box.process.stdin.compactMap(JSONValue.parse)
            .first { $0["method"]?.stringValue == "session/prompt" }
        #expect(prompt?["params"]?["sessionId"]?.stringValue == "ses_stored")
        #expect(try await store.session(id: session.id)?.agentSessionID == "ses_stored")
    }

    @Test("an effort the model offers is set after the model")
    func offeredEffortIsSet() async throws {
        let store = try makeTestStore("opencode-effort-offered")
        let session = try await makeOpenCodeSession(store, effort: "high")
        let box = scriptedBox(efforts: ["none", "high", "default"])
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("hello")
        let selected = configOptionsSent(box)
        #expect(selected.map(\.id) == ["model", "effort"])
        #expect(selected.last?.value == "high")
    }

    @Test("an effort left over from another model is dropped, and the turn still starts")
    func effortNotOfferedIsNotSent() async throws {
        let store = try makeTestStore("opencode-effort-missing")
        let session = try await makeOpenCodeSession(store, effort: "xhigh")
        let box = scriptedBox(efforts: ["none", "high", "default"])
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("hello")
        #expect(configOptionsSent(box).map(\.id) == ["model"])
        #expect(box.process.sentMethods.contains("session/prompt"))
    }

    @Test("a model picked between turns is set on the same process and the same session")
    func adoptedModelKeepsTheProcess() async throws {
        let store = try makeTestStore("opencode-adopt-model")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox(endsTurns: true)
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("one")
        await eventually("the first turn to end") {
            (try? await store.session(id: session.id))?.state == .idle
        }
        await runner.adoptComposerSettings(model: "ollama/other", effort: "")
        try await runner.send("two")

        #expect(box.processes.count == 1)
        #expect(box.process.sentMethods.filter { $0 == "session/new" }.count == 1)
        #expect(configOptionsSent(box).map(\.value) == [OpenCodeFixture.localModel, "ollama/other"])
    }

    @Test("a refused model fails the send, rather than running the turn on OpenCode's default")
    func refusedModelFailsTheSend() async throws {
        let store = try makeTestStore("opencode-model-refused")
        let session = try await makeOpenCodeSession(store, model: "nope/none")
        let box = scriptedBox()
        box.fail("session/set_config_option", code: -32602, message: "Invalid params: model not found: nope/none")
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        await #expect(throws: OpenCodeRunnerError.self) {
            try await runner.send("hello")
        }
        #expect(!box.process.sentMethods.contains("session/prompt"))
    }

    @Test("a deny is answered with OpenCode's one reject option")
    func denyAnswersWithReject() async throws {
        let store = try makeTestStore("opencode-deny")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("run it")
        box.process.emit(OpenCodeFixture.permissionLine(id: 0))
        await eventually("permission stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let ask = try #require(try await store.pendingPermissionAsks(sessionID: session.id).first)
        await runner.answer(requestID: ask.id, decision: .deny(message: "", endsTurn: false))
        #expect(box.process.stdin.compactMap(JSONValue.parse).contains {
            $0["id"]?.intValue == 0 && $0["result"]?["outcome"]?["optionId"]?.stringValue == "reject"
        })
    }

    @Test("stop answers a pending question as cancelled, then cancels the session")
    func stopCancelsPendingAsks() async throws {
        let store = try makeTestStore("opencode-stop")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("run it")
        box.process.emit(OpenCodeFixture.permissionLine(id: 0))
        await eventually("permission stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        runner.cancelNow()
        await eventually("session/cancel") {
            box.process.sentMethods.contains("session/cancel")
        }
        #expect(box.process.stdin.compactMap(JSONValue.parse).contains {
            $0["id"]?.intValue == 0 && $0["result"]?["outcome"]?["outcome"]?.stringValue == "cancelled"
        })
        #expect(try await store.pendingPermissionAsks(sessionID: session.id).isEmpty)
    }
}

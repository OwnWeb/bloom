import Testing
import Foundation
@testable import BloomCore

private func makeOpenCodeSession(
    _ store: Store,
    model: String = OpenCodeFixture.localModel,
    effort: String = "",
    permissionMode: PermissionMode = .auto,
    interactionMode: InteractionMode = .build,
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
        permissionMode: permissionMode,
        interactionMode: interactionMode
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
/// is never answered unless `endsTurns`, which ends every turn at once. `mode` is the server's
/// stored mode in every reply, `modes` what it offers.
private func scriptedBox(
    efforts: [String] = [], endsTurns: Bool = false, mode: String = "build", modes: [String] = ["build", "plan"]
) -> ProcessBox {
    let box = ProcessBox()
    box.reply(to: "initialize", with: .object([:]))
    var created = OpenCodeFixture.configOptions(model: OpenCodeFixture.hostedModel).objectValue ?? [:]
    created["sessionId"] = .string("ses_1")
    box.reply(to: "session/new", with: .object(created))
    box.reply(to: "session/resume", with: OpenCodeFixture.configOptions(
        model: OpenCodeFixture.localModel, mode: mode, modes: modes
    ))
    box.reply(to: "session/set_config_option", with: OpenCodeFixture.configOptions(
        model: OpenCodeFixture.localModel, efforts: efforts, mode: mode, modes: modes
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
    // A cap on "never", not a measurement: each condition is met as soon as the actor gets to it.
    await waitUntil(Comment(rawValue: description), within: .seconds(30), sourceLocation: sourceLocation, condition)
}

/// The runner's presentation events, collected for order checks.
private final class OpenCodeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) { lock.lock(); events.append(event); lock.unlock() }

    private var snapshot: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }

    func decided(endingIn suffix: String) -> Bool {
        snapshot.contains { if case .permissionDecided(let resolution) = $0 { resolution.requestID.hasSuffix(suffix) } else { false } }
    }

    /// The ask for this request is the event right before its decision, and appears nowhere else.
    func askIsFollowedByItsDecision(endingIn suffix: String) -> Bool {
        let all = snapshot
        let asks = all.indices.filter { if case .permissionAsk(let ask) = all[$0] { ask.requestID.hasSuffix(suffix) } else { false } }
        guard asks.count == 1, let index = asks.first, index + 1 < all.count,
              case .permissionDecided(let resolution) = all[index + 1] else { return false }
        return resolution.requestID.hasSuffix(suffix)
    }
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

    @Test("a resume refused because the session is gone opens a new one")
    func goneSessionIsReplaced() async throws {
        let store = try makeTestStore("opencode-resume-gone")
        let session = try await makeOpenCodeSession(store, agentSessionID: "ses_gone")
        let box = scriptedBox()
        box.fail("session/resume", code: OpenCodeRunner.invalidParamsCode, message: "Invalid params: session not found")
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("again")
        #expect(box.process.sentMethods.contains("session/new"))
    }

    @Test("a resume that fails for another reason keeps the stored session id")
    func failedResumeKeepsTheID() async throws {
        let store = try makeTestStore("opencode-resume-failed")
        let session = try await makeOpenCodeSession(store, agentSessionID: "ses_kept")
        let box = scriptedBox()
        let internalErrorCode = -32603
        box.fail("session/resume", code: internalErrorCode, message: "Internal error")
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        await #expect(throws: (any Error).self) { try await runner.send("again") }
        #expect(!box.process.sentMethods.contains("session/new"))
        #expect(try await store.session(id: session.id)?.agentSessionID == "ses_kept")
    }

    @Test("only a session that is not found counts as gone")
    func goneSessionWording() {
        let code = OpenCodeRunner.invalidParamsCode
        #expect(OpenCodeRunner.sessionIsGone(ACPRPCError(code: code, message: "Invalid params: session not found")))
        #expect(OpenCodeRunner.sessionIsGone(ACPRPCError(code: code, message: "Session ses_x not found")))
        #expect(!OpenCodeRunner.sessionIsGone(ACPRPCError(code: code, message: "Invalid params: model not found")))
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

    @Test("a plan session sets the mode after the model and before the prompt")
    func planModeIsSetBeforeThePrompt() async throws {
        let store = try makeTestStore("opencode-plan-mode")
        let session = try await makeOpenCodeSession(store, interactionMode: .plan)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("plan it")
        let selected = configOptionsSent(box)
        #expect(selected.map(\.id) == ["model", "mode"])
        #expect(selected.last?.value == "plan")
        let methods = box.process.sentMethods
        let lastSetting = try #require(methods.lastIndex(of: "session/set_config_option"))
        let prompt = try #require(methods.firstIndex(of: "session/prompt"))
        #expect(lastSetting < prompt)
    }

    @Test("a session the server still holds in plan is put back to build")
    func storedPlanIsPutBackToBuild() async throws {
        let store = try makeTestStore("opencode-plan-to-build")
        let session = try await makeOpenCodeSession(store, agentSessionID: "ses_1")
        let box = scriptedBox(mode: "plan")
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("build it")
        #expect(configOptionsSent(box).map(\.id) == ["model", "mode"])
        #expect(configOptionsSent(box).last?.value == "build")
    }

    @Test("a delivery's mode is the one set, over the session's")
    func deliveryModeWins() async throws {
        let store = try makeTestStore("opencode-delivery-mode")
        let session = try await makeOpenCodeSession(store, agentSessionID: "ses_1")
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        let delivery = try await store.enqueueDelivery(
            Delivery(targetSessionID: session.id, body: "plan it", interactionMode: .plan)
        )
        let claimed = try await store.claimDelivery(id: delivery.id)
        #expect(claimed)
        try await runner.sendDelivery(delivery)
        #expect(configOptionsSent(box).last?.value == "plan")
    }

    @Test("plan on a session that offers no plan mode fails the send rather than building")
    func planNotOfferedFailsTheSend() async throws {
        let store = try makeTestStore("opencode-plan-missing")
        let session = try await makeOpenCodeSession(store, interactionMode: .plan)
        let box = scriptedBox(modes: ["build"])
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        await #expect(throws: OpenCodeRunnerError.modeUnavailable(mode: "plan")) {
            try await runner.send("plan it")
        }
        #expect(!box.process.sentMethods.contains("session/prompt"))
    }

    @Test("a plan turn's last answer is recorded as the plan, and a build turn's is not", arguments: [
        InteractionMode.plan, .build,
    ])
    func planTurnRecordsItsAnswer(mode: InteractionMode) async throws {
        let store = try makeTestStore("opencode-plan-artefact-\(mode.rawValue)")
        let session = try await makeOpenCodeSession(store, interactionMode: mode)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("plan it")
        let prompt = try #require(box.process.sentFrame { $0["method"]?.stringValue == "session/prompt" })
        let promptID = try #require(prompt["id"])
        box.process.emit(Self.textChunkLine("1. Add subtract.\n2. Test it."))
        box.process.emit("{\"jsonrpc\":\"2.0\",\"id\":\(promptID.compactJSON),\"result\":{\"stopReason\":\"end_turn\"}}")
        await eventually("the turn to end") {
            (try? await store.session(id: session.id))?.state == .idle
        }
        let plans = try await store.planArtefacts(sessionID: session.id)
        #expect(plans.map(\.markdown) == (mode == .plan ? ["1. Add subtract.\n2. Test it."] : []))
    }

    private static func textChunkLine(_ text: String) -> String {
        let params = JSONValue.object(["sessionId": .string("ses_1"), "update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ])])
        return "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":\(params.compactJSON)}"
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

    @Test("a command allowed for this session is answered by Bloom the next time it is asked")
    func sessionGrantAnswersTheNextAsk() async throws {
        let store = try makeTestStore("opencode-session-grant")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }
        let seen = OpenCodeEventLog()
        let events = runner.events
        let listening = Task { for await event in events { seen.append(event) } }
        defer { listening.cancel() }

        try await runner.send("run it")
        box.process.emit(OpenCodeFixture.permissionLine(id: 0))
        await eventually("first question stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let ask = try #require(try await store.pendingPermissionAsks(sessionID: session.id).first)
        await runner.answer(requestID: ask.id, decision: .allow(scope: .session))

        box.process.emit(OpenCodeFixture.permissionLine(id: 1))
        await eventually("the second question answered without a card") {
            box.process.stdin.compactMap(JSONValue.parse).contains {
                $0["id"]?.intValue == 1 && $0["result"]?["outcome"]?["optionId"]?.stringValue == "once"
            }
        }
        await eventually("both questions resolved in the store") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? [ask]).isEmpty
        }
        let decisions = try await store.permissionAskDecisions(sessionID: session.id)
        let sessionAllow = PermissionDecision.allow(scope: .session).storedName
        #expect(decisions.values.filter { $0 == sessionAllow }.count == 2)
        #expect(!decisions.values.contains(PermissionAskOutcome.auto))

        // The granted question is drawn only together with its answer, never as a card first.
        await eventually("the granted question's events") { seen.decided(endingIn: ":1") }
        #expect(seen.askIsFollowedByItsDecision(endingIn: ":1"))
    }

    @Test("a session grant is forgotten with the process")
    func sessionGrantEndsWithTheProcess() async throws {
        let store = try makeTestStore("opencode-session-grant-forgotten")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("run it")
        box.process.emit(OpenCodeFixture.permissionLine(id: 0))
        await eventually("first question stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let ask = try #require(try await store.pendingPermissionAsks(sessionID: session.id).first)
        await runner.answer(requestID: ask.id, decision: .allow(scope: .session))
        box.process.endOutput()
        await eventually("the process to be gone") { await !runner.isProcessAlive }

        try await runner.send("again")
        let second = box.process
        second.emit(OpenCodeFixture.permissionLine(id: 0))
        await eventually("the same question stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        // A question a session grant answered was never queued, so this deny would write nothing.
        let again = try #require(try await store.pendingPermissionAsks(sessionID: session.id).first)
        await runner.answer(requestID: again.id, decision: .deny(message: "", endsTurn: false))
        let answers = second.stdin.compactMap(JSONValue.parse)
            .filter { $0["id"]?.intValue == 0 && $0["result"] != nil }
            .compactMap { $0["result"]?["outcome"]?["optionId"]?.stringValue }
        #expect(answers == ["reject"])
    }

    @Test("a question from a process that closed is stopped, and a late answer writes nothing")
    func closedProcessStopsItsQuestions() async throws {
        let store = try makeTestStore("opencode-closed-ask")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("run it")
        box.process.emit(OpenCodeFixture.permissionLine(id: 0))
        await eventually("question stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let ask = try #require(try await store.pendingPermissionAsks(sessionID: session.id).first)
        box.process.endOutput()
        await eventually("question stopped") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).isEmpty
        }
        await runner.answer(requestID: ask.id, decision: .allow(scope: .project))
        #expect(!box.process.stdin.compactMap(JSONValue.parse).contains { $0["id"]?.intValue == 0 && $0["result"] != nil })
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

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

private func promptTexts(_ box: ProcessBox) -> [String] {
    box.process.stdin.compactMap(JSONValue.parse)
        .filter { $0["method"]?.stringValue == "session/prompt" }
        .compactMap { $0["params"]?["prompt"]?[0]?["text"]?.stringValue }
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
        let plans = try await planArtefacts(mode: mode, stopReason: "end_turn")
        #expect(plans == (mode == .plan ? ["1. Add subtract.\n2. Test it."] : []))
    }

    @Test("a plan turn that ends on a question records no plan")
    func questionPlanTurnRecordsNothing() async throws {
        #expect(try await planArtefacts(mode: .plan, stopReason: "end_turn", reply: "Which framework?").isEmpty)
    }

    /// A refusal reads as a finished turn rather than an error, so only the stop reason keeps its
    /// preamble from becoming the plan.
    @Test("a plan turn ended by a refused card records no plan")
    func refusedPlanTurnRecordsNothing() async throws {
        #expect(try await planArtefacts(mode: .plan, stopReason: "cancelled", refusingATool: true).isEmpty)
    }

    private func planArtefacts(
        mode: InteractionMode, stopReason: String, refusingATool: Bool = false,
        reply: String = "1. Add subtract.\n2. Test it."
    ) async throws -> [String] {
        let store = try makeTestStore("opencode-plan-artefact-\(mode.rawValue)-\(stopReason)-\(reply.count)")
        let session = try await makeOpenCodeSession(store, interactionMode: mode)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("plan it")
        let prompt = try #require(box.process.sentFrame { $0["method"]?.stringValue == "session/prompt" })
        let promptID = try #require(prompt["id"])
        box.process.emit(Self.textChunkLine(reply))
        if refusingATool { box.process.emit(Self.declinedToolLine()) }
        box.process.emit(Self.promptReplyLine(id: promptID, stopReason: stopReason))
        await eventually("the turn to end") {
            (try? await store.session(id: session.id))?.state.isMidTurn == false
        }
        return try await store.planArtefacts(sessionID: session.id).map(\.markdown)
    }

    private static func promptReplyLine(id: JSONValue, stopReason: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id.compactJSON),\"result\":{\"stopReason\":\"\(stopReason)\"}}"
    }

    private static func declinedToolLine() -> String {
        let params = JSONValue.object(["sessionId": .string("ses_1"), "update": .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("call_declined"),
            "status": .string("failed"),
            "kind": .string("execute"),
            "title": .string("shell"),
            "rawOutput": .object(["error": .string(OpenCodeTranslation.declinedMessage)]),
        ])])
        return "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":\(params.compactJSON)}"
    }

    private static func textChunkLine(_ text: String) -> String {
        let params = JSONValue.object(["sessionId": .string("ses_1"), "update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ])])
        return "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":\(params.compactJSON)}"
    }

    @Test("a /btw conversation's first question carries the parent's context, and only the first")
    func sideConversationCarriesContextOnce() async throws {
        let store = try makeTestStore("opencode-side-conversation")
        let parent = try await makeOpenCodeSession(store, agentSessionID: "ses_parent")
        let child = try await store.openSideConversation(parentID: parent.id, streamingText: "Original context")
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: child, box: box)
        defer { runner.terminateNow() }

        try await runner.send("Why?")
        let prompt = try #require(box.process.sentFrame { $0["method"]?.stringValue == "session/prompt" })
        box.process.emit(Self.textChunkLine("Because."))
        box.process.emit(Self.promptReplyLine(id: try #require(prompt["id"]), stopReason: "end_turn"))
        await eventually("the first turn to end") {
            (try? await store.session(id: child.id))?.state.isMidTurn == false
        }
        try await runner.send("And then?")

        let prompts = promptTexts(box)
        #expect(prompts.count == 2)
        #expect(prompts.first?.contains("Original context") == true)
        #expect(prompts.last == "And then?")
        #expect(try await store.setting(SideConversation.contextDeliveredKey(child.id)) == "1")
        let questions = try await store.messages(sessionID: child.id).filter { $0.kind == .user }
        #expect(questions.map { UserTurnPrompt.text(in: $0.payload) } == ["Why?", "And then?"])
    }

    @Test("a refused first /btw question is retried with the parent's context still on it")
    func refusedSideQuestionKeepsItsContext() async throws {
        let store = try makeTestStore("opencode-side-conversation-refused")
        let parent = try await makeOpenCodeSession(store, agentSessionID: "ses_parent")
        let child = try await store.openSideConversation(parentID: parent.id, streamingText: "Original context")
        // Answered rather than ignored, because an ignored method is never refused either.
        let box = scriptedBox(endsTurns: true)
        box.fail("session/prompt", code: -32603, message: "Internal error: active ACP prompt")
        let runner = makeRunner(store: store, session: child, box: box)
        defer { runner.terminateNow() }

        try await runner.send("Why?")
        await eventually("the refused turn to end") {
            (try? await store.session(id: child.id))?.state.isMidTurn == false
        }
        try await runner.send("Why?")

        let prompts = promptTexts(box)
        #expect(prompts.count == 2)
        #expect(prompts.allSatisfy { $0.contains("Original context") })
        #expect(try await store.setting(SideConversation.contextDeliveredKey(child.id)) == nil)
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

// MARK: - Steering

private func steerTexts(_ box: ProcessBox) -> [String] {
    box.process.stdin.compactMap(JSONValue.parse)
        .filter { $0["method"]?.stringValue == "_session/steering" }
        .compactMap { $0["params"]?["prompt"]?[0]?["text"]?.stringValue }
}

private func steerReply(_ outcome: String) -> JSONValue {
    outcome == "injected"
        ? .object(["outcome": .string(outcome)])
        : .object(["outcome": .string(outcome), "reason": .string("noRunningTurn")])
}

private func userTexts(_ store: Store, _ session: Session) async throws -> [String] {
    try await store.messages(sessionID: session.id).filter { $0.kind == .user }
        .map { UserTurnPrompt.text(in: $0.payload) }
}

/// Counts the streamed chunks the runner has handled, so a test can steer after a chunk it emitted
/// rather than racing the runner to it.
private final class StreamedChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0

    init(_ runner: OpenCodeRunner) {
        let events = runner.events
        Task { [weak self] in
            for await event in events {
                if case .streamDelta = event { self?.bump() }
            }
        }
    }

    private func bump() { lock.lock(); seen += 1; lock.unlock() }

    var count: Int { lock.lock(); defer { lock.unlock() }; return seen }
}

private func notices(_ store: Store, _ session: Session) async throws -> [String] {
    try await store.messages(sessionID: session.id).filter { $0.kind == .notice }
        .compactMap { OpenCodeSteerNote.sentence(fromNote: $0.payload) }
}

/// Measured on 2.3.2: see "Steering" in `docs/OPENCODE.md`.
extension OpenCodeRunnerTests {
    @Test("a message sent during a turn is steered into it, and its row is written once")
    func midTurnMessageIsSteered() async throws {
        let store = try makeTestStore("opencode-steer")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("injected"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("first")
        try await runner.send("and also this")

        #expect(promptTexts(box) == ["first"])
        #expect(steerTexts(box) == ["and also this"])
        let steer = try #require(box.process.sentFrame { $0["method"]?.stringValue == "_session/steering" })
        #expect(steer["params"]?["sessionId"]?.stringValue == "ses_1")
        #expect(try await userTexts(store, session) == ["first", "and also this"])
        #expect(try await store.session(id: session.id)?.state.isMidTurn == true)
    }

    @Test("a delivery steered into a turn is accepted, without a prompt of its own")
    func steeredDeliveryIsAccepted() async throws {
        let store = try makeTestStore("opencode-steer-delivery")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("injected"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("first")
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "follow up"))
        _ = try await store.claimDelivery(id: delivery.id)
        try await runner.sendDelivery(delivery)

        #expect(promptTexts(box) == ["first"])
        #expect(steerTexts(box) == ["follow up"])
        #expect(try await store.delivery(id: delivery.id)?.state == .accepted)
        #expect(try await userTexts(store, session) == ["first", "follow up"])
    }

    @Test("a steer that missed the turn waits for its result, then starts a turn of its own")
    func missedSteerPromptsAfterTheTurnEnds() async throws {
        let store = try makeTestStore("opencode-steer-missed")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("promptRequired"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("first")
        let first = try #require(box.process.sentFrame { $0["method"]?.stringValue == "session/prompt" })
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "late"))
        _ = try await store.claimDelivery(id: delivery.id)
        let sending = Task { try await runner.sendDelivery(delivery) }
        await eventually("the steer is answered") { steerTexts(box) == ["late"] }
        // The server closed the turn before the steer reached it, so its reply is on its way.
        box.process.emit(Self.promptReplyLine(id: try #require(first["id"]), stopReason: "end_turn"))
        try await sending.value

        #expect(promptTexts(box) == ["first", "late"])
        #expect(try await store.delivery(id: delivery.id)?.state == .accepted)
        #expect(try await userTexts(store, session) == ["first", "late"])
        // The first turn's result was filed rather than dropped behind the second turn.
        #expect(try await store.messages(sessionID: session.id).contains { $0.kind == .result })
        #expect(try await store.session(id: session.id)?.state.isMidTurn == true)
    }

    @Test("a steer that fails without an answer starts no turn, and its delivery stays uncertain")
    func ambiguousSteerFailureStartsNothing() async throws {
        let store = try makeTestStore("opencode-steer-ambiguous")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.fail("_session/steering", code: -32603, message: "internal failure after dispatch")
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("first")
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "follow up"))
        _ = try await store.claimDelivery(id: delivery.id)
        await #expect(throws: ACPRPCError.self) { try await runner.sendDelivery(delivery) }

        #expect(promptTexts(box) == ["first"])
        #expect(try await store.delivery(id: delivery.id)?.state == .uncertain)
    }

    @Test("a stopped turn is not steered into: the next message starts a turn")
    func stoppedTurnIsNotSteered() async throws {
        let store = try makeTestStore("opencode-steer-stopped")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("injected"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("first")
        let first = try #require(box.process.sentFrame { $0["method"]?.stringValue == "session/prompt" })
        runner.cancelNow()
        await eventually("session/cancel") { box.process.sentMethods.contains("session/cancel") }
        box.process.emit(Self.promptReplyLine(id: try #require(first["id"]), stopReason: "cancelled"))
        try await runner.send("again")

        #expect(steerTexts(box).isEmpty)
        #expect(promptTexts(box) == ["first", "again"])
        #expect(try await notices(store, session).isEmpty)
    }

    @Test("a stop that overtakes unanswered steered words says they go with the next message")
    func stopOverUnreadSteerWritesANotice() async throws {
        let store = try makeTestStore("opencode-steer-unread")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("injected"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        let chunks = StreamedChunks(runner)
        try await runner.send("first")
        box.process.emit(Self.textChunkLine("Working on it.", messageID: "msg_1"))
        await eventually("the chunk is handled") { chunks.count == 1 }
        try await runner.send("and also this")
        runner.cancelNow()

        await eventually("the notice") { (try? await notices(store, session))?.count == 1 }
        #expect(try await notices(store, session) == [OpenCodeSteerNote.sentence])
    }

    @Test("a stop after the steered words were answered writes no notice")
    func stopAfterAnsweredSteerIsSilent() async throws {
        let store = try makeTestStore("opencode-steer-answered")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("injected"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        let chunks = StreamedChunks(runner)
        try await runner.send("first")
        box.process.emit(Self.textChunkLine("Working on it.", messageID: "msg_1"))
        await eventually("the chunk is handled") { chunks.count == 1 }
        try await runner.send("and also this")
        box.process.emit(Self.textChunkLine("Noted.", messageID: "msg_2"))
        await eventually("the answer is handled") { chunks.count == 2 }
        runner.cancelNow()
        await eventually("session/cancel") { box.process.sentMethods.contains("session/cancel") }

        #expect(try await notices(store, session).isEmpty)
    }

    @Test("a stop while the steer is on the wire leaves the note to the steer's reply")
    func stopDuringSteerWritesTheNoteOnce() async throws {
        let store = try makeTestStore("opencode-steer-on-wire")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.ignore("_session/steering")
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("first")
        let sending = Task { try await runner.send("and also this") }
        await eventually("the steer is sent") { steerTexts(box) == ["and also this"] }
        runner.cancelNow()
        await eventually("session/cancel") { box.process.sentMethods.contains("session/cancel") }
        let steer = try #require(box.process.sentFrame { $0["method"]?.stringValue == "_session/steering" })
        let steerID = try #require(steer["id"])
        box.process.emit("{\"jsonrpc\":\"2.0\",\"id\":\(steerID.compactJSON),\"result\":{\"outcome\":\"injected\"}}")
        try await sending.value

        await eventually("the notice") { (try? await notices(store, session))?.count == 1 }
        #expect(try await notices(store, session) == [OpenCodeSteerNote.sentence])
    }

    @Test("a steer that missed, then a stop before its prompt, gives the delivery back to the queue's claim")
    func missedSteerThenStopReturnsTheClaim() async throws {
        let store = try makeTestStore("opencode-steer-missed-stopped")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("promptRequired"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("first")
        let first = try #require(box.process.sentFrame { $0["method"]?.stringValue == "session/prompt" })
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "late"))
        _ = try await store.claimDelivery(id: delivery.id)
        let sending = Task { try await runner.sendDelivery(delivery) }
        await eventually("the steer is answered") { steerTexts(box) == ["late"] }
        runner.cancelNow()
        await eventually("session/cancel") { box.process.sentMethods.contains("session/cancel") }
        box.process.emit(Self.promptReplyLine(id: try #require(first["id"]), stopReason: "cancelled"))
        await #expect(throws: CancellationError.self) { try await sending.value }

        #expect(promptTexts(box) == ["first"])
        // Nothing reached the agent, so the drain may release it back to pending.
        #expect(try await store.delivery(id: delivery.id)?.state == .claimed)
    }

    @Test("a steered delivery's row is written when it is claimed, above the answer it interrupts")
    func steeredDeliveryRowComesFirst() async throws {
        let store = try makeTestStore("opencode-steer-delivery-order")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("injected"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        let chunks = StreamedChunks(runner)
        try await runner.send("first")
        box.process.emit(Self.textChunkLine("Before.", messageID: "msg_1"))
        await eventually("the chunk is handled") { chunks.count == 1 }
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "steered"))
        _ = try await store.claimDelivery(id: delivery.id)
        try await runner.sendDelivery(delivery)
        box.process.emit(Self.textChunkLine("After.", messageID: "msg_2"))
        let first = try #require(box.process.sentFrame { $0["method"]?.stringValue == "session/prompt" })
        box.process.emit(Self.promptReplyLine(id: try #require(first["id"]), stopReason: "end_turn"))
        await eventually("the turn to end") {
            (try? await store.session(id: session.id))?.state.isMidTurn == false
        }

        // The claim wrote the row before the runner saw the delivery, so the answer streamed until
        // then lands under it. The reply is still a row of its own.
        let rows = try await store.messages(sessionID: session.id).filter { [.user, .assistantText].contains($0.kind) }
        #expect(rows.map(\.kind) == [.user, .user, .assistantText, .assistantText])
    }

    @Test("the answer so far is its own row above the steered words, and the reply a row below")
    func steerSplitsTheAnswer() async throws {
        let store = try makeTestStore("opencode-steer-order")
        let session = try await makeOpenCodeSession(store)
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("injected"))
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        let chunks = StreamedChunks(runner)
        try await runner.send("first")
        box.process.emit(Self.textChunkLine("Before.", messageID: "msg_1"))
        await eventually("the chunk is handled") { chunks.count == 1 }
        try await runner.send("steered")
        box.process.emit(Self.textChunkLine("After.", messageID: "msg_2"))
        let first = try #require(box.process.sentFrame { $0["method"]?.stringValue == "session/prompt" })
        box.process.emit(Self.promptReplyLine(id: try #require(first["id"]), stopReason: "end_turn"))
        await eventually("the turn to end") {
            (try? await store.session(id: session.id))?.state.isMidTurn == false
        }

        let rows = try await store.messages(sessionID: session.id).filter { [.user, .assistantText].contains($0.kind) }
        #expect(rows.map(\.kind) == [.user, .assistantText, .user, .assistantText])
    }

    @Test("a steer in a /btw conversation sends the words alone, never the parent's context")
    func sideConversationSteerIsRaw() async throws {
        let store = try makeTestStore("opencode-steer-side")
        let parent = try await makeOpenCodeSession(store, agentSessionID: "ses_parent")
        let child = try await store.openSideConversation(parentID: parent.id, streamingText: "Original context")
        let box = scriptedBox()
        box.reply(to: "_session/steering", with: steerReply("injected"))
        let runner = makeRunner(store: store, session: child, box: box)
        defer { runner.terminateNow() }

        try await runner.send("Why?")
        try await runner.send("Briefly.")

        #expect(promptTexts(box).first?.contains("Original context") == true)
        #expect(steerTexts(box) == ["Briefly."])
    }

    private static func textChunkLine(_ text: String, messageID: String) -> String {
        let params = JSONValue.object(["sessionId": .string("ses_1"), "update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "messageId": .string(messageID),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ])])
        return "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":\(params.compactJSON)}"
    }
}

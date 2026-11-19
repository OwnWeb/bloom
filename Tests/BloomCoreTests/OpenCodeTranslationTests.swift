import Testing
import Foundation
@testable import BloomCore

@Suite("OpenCode translation")
struct OpenCodeTranslationTests {
    private func ready(model: String = OpenCodeFixture.localModel) -> OpenCodeTranslation {
        var translation = OpenCodeTranslation(context: OpenCodeTranslation.Context(model: model, cwd: "/tmp/w"))
        _ = translation.translate(.sessionReady(OpenCodeSession(id: "ses_1")))
        return translation
    }

    @Test("session ready is a stored init line naming OpenCode and the composer's model")
    func sessionReadyIsInit() {
        var translation = OpenCodeTranslation(context: OpenCodeTranslation.Context(
            model: OpenCodeFixture.localModel, cwd: "/tmp/w", permissionMode: "auto"
        ))
        // The session opens on OpenCode's own default, which is not what the chat will run.
        let events = translation.translate(.sessionReady(OpenCodeSession(
            id: "ses_1",
            options: OpenCodeConfigOptions(currentModel: OpenCodeFixture.hostedModel)
        )))
        guard case .initialized(let value) = events.first else {
            Issue.record("expected init")
            return
        }
        #expect(value.sessionID == "ses_1")
        #expect(value.agentKind == .openCode)
        #expect(value.model == OpenCodeFixture.localModel)
        #expect(JSONValue.parse(value.raw)?["agent_kind"]?.stringValue == "openCode")
    }

    @Test("a pending tool call writes no row, because its input arrives with the next frame")
    func toolRowWaitsForItsInput() {
        var translation = ready()
        let pending = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_1"),
            "name": .string("shell"),
            "title": .string("shell"),
            "kind": .string("execute"),
            "status": .string("pending"),
            "rawInput": .object(["cwd": .string("/tmp/w")]),
        ], isUpdate: false)))
        #expect(pending.isEmpty)

        let running = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_1"),
            "status": .string("in_progress"),
            "kind": .string("execute"),
            "title": .string("ls"),
            "rawInput": .object(["command": .string("ls"), "cwd": .string("/tmp/w")]),
        ], isUpdate: true)))
        guard case .toolUse(let use) = running.first else {
            Issue.record("expected tool use")
            return
        }
        #expect(use.id == "call_1")
        #expect(use.name == "Bash")
        #expect(use.input["command"]?.stringValue == "ls")
        #expect(OpenCodeTranslation.isOpenCodeCall(use.input))

        // OpenCode repeats `in_progress`. The row is written once.
        let repeated = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_1"),
            "status": .string("in_progress"),
            "rawInput": .object(["command": .string("ls"), "cwd": .string("/tmp/w")]),
        ], isUpdate: true)))
        #expect(repeated.isEmpty)
    }

    @Test("a completed update becomes a result row, and an image block is not poured into it")
    func completedToolBecomesAResult() {
        var translation = ready()
        _ = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_r"),
            "name": .string("read"),
            "kind": .string("read"),
            "status": .string("in_progress"),
            "rawInput": .object(["path": .string(".bloom/attachments/x/img.png")]),
        ], isUpdate: false)))
        let done = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_r"),
            "status": .string("completed"),
            "content": .array([
                .object(["type": .string("content"), "content": .object([
                    "type": .string("text"), "text": .string("Image read successfully"),
                ])]),
                .object(["type": .string("content"), "content": .object([
                    "type": .string("image"), "mimeType": .string("image/png"), "data": .string("iVBORw0KGgo"),
                ])]),
            ]),
        ], isUpdate: true)))
        guard case .toolResult(let result) = done.first else {
            Issue.record("expected tool result")
            return
        }
        #expect(result.toolUseID == "call_r")
        #expect(result.text == "Image read successfully")
        #expect(!result.isError)
    }

    @Test("a tool call that finishes before it ever ran still gets its row and its result")
    func toolThatNeverRanIsStillShown() {
        var translation = ready()
        _ = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_x"), "name": .string("tools"), "status": .string("pending"),
        ], isUpdate: false)))
        let failed = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_x"),
            "status": .string("failed"),
            "rawOutput": .object(["error": .string("No tool named \"tools\" is currently available.")]),
        ], isUpdate: true)))
        #expect(failed.count == 2)
        guard case .toolUse(let use) = failed.first, case .toolResult(let result) = failed.last else {
            Issue.record("expected a tool use and its result")
            return
        }
        #expect(use.name == "tools")
        #expect(result.isError)
        #expect(result.refusal == nil)
    }

    @Test("a rejected permission arrives as a failed call, and is filed as a refusal")
    func declinedToolIsARefusal() {
        var translation = ready()
        _ = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_d"),
            "name": .string("shell"),
            "status": .string("in_progress"),
            "rawInput": .object(["command": .string("echo two")]),
        ], isUpdate: false)))
        let declined = translation.translate(.update(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_d"),
            "status": .string("failed"),
            "content": .array([.object(["type": .string("content"), "content": .object([
                "type": .string("text"), "text": .string("The user declined this tool call"),
            ])])]),
            "rawOutput": .object(["metadata": .object([:]), "error": .string("The user declined this tool call")]),
        ], isUpdate: true)))
        guard case .toolResult(let result) = declined.first else {
            Issue.record("expected tool result")
            return
        }
        #expect(result.refusal == .denied)
        #expect(result.isError)
    }

    @Test("the gauge comes from usage_update and the output tokens from the prompt reply")
    func usageComesFromBothPlaces() {
        var translation = ready()
        _ = translation.translate(.update(ACPSessionUpdate(
            sessionID: "ses_1", kind: .usage(used: 6581, size: 262_144), raw: .object([:])
        )))
        let done = translation.translate(.promptCompleted(ACPPromptResult(
            requestID: .number(5),
            sessionID: "",
            stopReason: "end_turn",
            raw: .object(["stopReason": .string("end_turn"), "usage": .object([
                "inputTokens": .integer(80), "outputTokens": .integer(188), "totalTokens": .integer(19_507),
            ])])
        )))
        guard case .result(let result) = done.last else {
            Issue.record("expected result")
            return
        }
        #expect(!result.isError)
        #expect(result.usage.inputTokens == 6581)
        #expect(result.usage.contextTokens == 262_144)
        #expect(result.usage.outputTokens == 188)
    }

    @Test("a prompt the provider failed is an error result carrying OpenCode's sentence")
    func failedPromptIsAnErrorResult() {
        var translation = ready()
        let done = translation.translate(.promptCompleted(ACPPromptResult(
            requestID: .number(4),
            sessionID: "",
            stopReason: "refusal",
            raw: .object(["message": .string("Internal error: ECONNREFUSED: Unable to connect.")])
        )))
        guard case .result(let result) = done.last else {
            Issue.record("expected result")
            return
        }
        #expect(result.isError)
        #expect(result.summary == "Internal error: ECONNREFUSED: Unable to connect.")
    }

    @Test("tool names land on the presenters Bloom already has, and an unknown one is kept")
    func toolNames() {
        func name(_ raw: String) -> String {
            OpenCodeTranslation.toolName(for: ACPToolCall.decode(.object(["name": .string(raw)]), isUpdate: false))
        }
        #expect(name("read") == "Read")
        #expect(name("write") == "Write")
        #expect(name("shell") == "Bash")
        // How OpenCode reaches MCP tools. There is no presenter for it, so the name is kept.
        #expect(name("execute") == "execute")
        #expect(name("") == "OpenCode.tool")
    }
}

@Suite("OpenCode permission")
struct OpenCodePermissionTests {
    private func request() throws -> ACPPermissionRequest {
        try #require(ACPPermissionRequest.decode(ACPServerRequest(
            id: .number(0), method: "session/request_permission", params: OpenCodeFixture.permissionRequest()
        )))
    }

    @Test("an ask reads as a Bash question with a session grant on offer")
    func askShape() throws {
        let ask = OpenCodePermission.ask(for: try request())
        #expect(ask.toolName == "Bash")
        #expect(ask.toolUseID == "call_w5isigpu")
        #expect(ask.input["command"]?.stringValue == "echo \"two\"")
        #expect(!ask.suppressesAlwaysAllow)
        #expect(ask.suggestions.first?.rules.first?.ruleContent == "echo \"two\"")
        #expect(JSONValue.parse(ask.raw)?["agent_kind"]?.stringValue == "openCode")
    }

    @Test("each decision maps onto one of the three options OpenCode offers")
    func decisionsMapOntoOptions() throws {
        let request = try request()
        #expect(OpenCodePermission.optionID(for: .allow(scope: .once), in: request) == "once")
        // `allow_always` outlives the session in OpenCode's own data, so Bloom keeps the grant.
        #expect(OpenCodePermission.optionID(for: .allow(scope: .session), in: request) == "once")
        #expect(OpenCodePermission.optionID(for: .allow(scope: .project), in: request) == "once")
        // One reject, whatever the deny was meant to do to the turn.
        #expect(OpenCodePermission.optionID(for: .deny(message: "", endsTurn: false), in: request) == "reject")
        #expect(OpenCodePermission.optionID(for: .deny(message: "", endsTurn: true), in: request) == "reject")
    }

    @Test("request ids from two connections never collide, since both count from zero")
    func requestIDsCarryTheConnection() {
        let first = OpenCodePermission.requestID(.number(0), sessionID: "ses_1", connectionID: UUID())
        let second = OpenCodePermission.requestID(.number(0), sessionID: "ses_1", connectionID: UUID())
        #expect(first != second)
    }
}

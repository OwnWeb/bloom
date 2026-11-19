import Foundation

/// Turns OpenCode's ACP updates into the vocabulary Bloom already stores and draws.
///
/// The same job `GrokTranslation` does, for the same reason: stored rows are written in Claude
/// Code's stream-json shape so a chat reads back after a restart. The differences are OpenCode's,
/// measured on 2.3.2 (`docs/OPENCODE.md`): a tool call is announced with an empty input and
/// filled in by its first update, a declined call arrives as `failed`, and the turn's output
/// tokens are on the prompt reply.
public struct OpenCodeTranslation: Sendable {
    public struct Context: Sendable, Hashable {
        public var model: String
        public var cwd: String
        public var permissionMode: String
        public var version: String

        public init(model: String = "", cwd: String = "", permissionMode: String = "", version: String = "") {
            self.model = model
            self.cwd = cwd
            self.permissionMode = permissionMode
            self.version = version
        }
    }

    public var context: Context
    public private(set) var usage = AgentUsage()
    public private(set) var sessionID = ""

    private var text = ""
    private var thought = ""
    private var tools: [String: ACPToolCall] = [:]
    /// Tool calls whose row has been written. One waits for its input before it is.
    private var announced: Set<String> = []
    private var textMessageID = ""
    private var thoughtMessageID = ""

    public init(context: Context = Context()) {
        self.context = context
    }

    /// The key the raw ACP tool call is carried under, and the marker of an OpenCode row.
    public static let itemKey = "openCodeItem"

    public static func isOpenCodeCall(_ input: JSONValue) -> Bool {
        input[itemKey] != nil
    }

    /// The name an OpenCode tool is filed under in Bloom's existing presenters.
    ///
    /// OpenCode's names are lower case (`read`, `write`, `shell`) and `ToolPresenter` switches on
    /// Claude Code's. An unmapped name is kept, so `execute`, which is how OpenCode reaches MCP
    /// tools, still has a fallback row.
    public static func toolName(for call: ACPToolCall) -> String {
        switch call.toolName {
        case "read": return "Read"
        case "write": return "Write"
        case "edit", "patch": return "Edit"
        case "shell", "bash": return "Bash"
        case "grep": return "Grep"
        case "glob", "list": return "Glob"
        case "websearch": return "WebSearch"
        case "webfetch": return "WebFetch"
        case "todowrite": return "TodoWrite"
        case "task": return "Task"
        case "": return "OpenCode.\(call.kind.isEmpty ? "tool" : call.kind)"
        default: return call.toolName
        }
    }

    /// Lift `path` onto `file_path` so `PermissionAsk.subject` and `AgentToolUse.filePath` work
    /// without knowing anything about OpenCode. The whole ACP object travels underneath.
    public static func input(for call: ACPToolCall) -> JSONValue {
        var members = call.rawInput.objectValue ?? [:]
        if members["file_path"] == nil {
            if let path = members["path"] {
                members["file_path"] = path
            } else if !call.path.isEmpty {
                members["file_path"] = .string(call.path)
            }
        }
        if members["query"] == nil, let query = members["pattern"] {
            members["query"] = query
        }
        members[itemKey] = call.json
        return .object(members)
    }

    /// The sentence OpenCode fails a tool call with when the permission was rejected.
    static let declinedMessage = "The user declined this tool call"

    static func wasDeclined(_ call: ACPToolCall) -> Bool {
        call.status == "cancelled" || call.rawOutput["error"]?.stringValue == declinedMessage
    }

    // MARK: - Translating

    public mutating func translate(_ event: OpenCodeEvent) -> [AgentEvent] {
        switch event {
        case .sessionReady(let session):
            sessionID = session.id
            if context.model.isEmpty { context.model = session.options.currentModel }
            return [.initialized(AgentInit(
                sessionID: session.id,
                cwd: context.cwd,
                model: context.model,
                permissionMode: context.permissionMode,
                agentKind: .openCode,
                version: context.version,
                raw: Self.initLine(sessionID: session.id, context: context)
            ))]

        case .update(let update):
            if !update.sessionID.isEmpty { sessionID = update.sessionID }
            return updateEvents(update)

        case .promptCompleted(let result):
            if !result.sessionID.isEmpty { sessionID = result.sessionID }
            usage.outputTokens = result.raw["usage"]?["outputTokens"]?.intValue ?? 0
            var events = flushOpenBlocks()
            events.append(.result(self.result(for: result)))
            tools.removeAll()
            announced.removeAll()
            return events

        case .closed(let reason):
            return finishInterruptedTurn()
                + [.error(AgentError(message: reason, raw: Self.errorLine(message: reason)))]

        case .permission, .unknown:
            return []
        }
    }

    /// An interrupted turn might never send its completion. Keep its partial answer in its own
    /// row before another prompt arrives, and discard tool state belonging to that turn.
    public mutating func finishInterruptedTurn() -> [AgentEvent] {
        let events = flushOpenBlocks()
        tools.removeAll()
        announced.removeAll()
        return events
    }

    private mutating func updateEvents(_ update: ACPSessionUpdate) -> [AgentEvent] {
        switch update.kind {
        case .text(let chunk):
            guard !chunk.isEmpty else { return [] }
            var events = flushThought()
            if text.isEmpty { textMessageID = UUID().uuidString }
            text += chunk
            events.append(.streamDelta(.text(chunk)))
            return events

        case .thought(let chunk):
            guard !chunk.isEmpty else { return [] }
            if thought.isEmpty { thoughtMessageID = UUID().uuidString }
            thought += chunk
            return [.streamDelta(.thinking(chunk))]

        case .toolCall(let call), .toolCallUpdate(let call):
            let stored = merged(call, onto: tools[call.id])
            tools[call.id] = stored
            var events: [AgentEvent] = []
            // The `pending` frame has no input yet (a shell call has only its `cwd`), and a row
            // written then would never show a command. The input arrives with `in_progress`.
            if !announced.contains(stored.id), stored.status != "pending" {
                announced.insert(stored.id)
                events = flushOpenBlocks() + [toolUse(for: stored)]
            }
            if stored.isFinished { events.append(contentsOf: toolResult(for: stored)) }
            return events

        case .usage(let used, let size):
            usage.inputTokens = used
            usage.contextTokens = size
            return []

        case .other:
            return []
        }
    }

    private mutating func flushOpenBlocks() -> [AgentEvent] {
        flushThought() + flushText()
    }

    private mutating func flushText() -> [AgentEvent] {
        let finished = text
        text = ""
        guard !finished.isEmpty else { return [] }
        let messageID = textMessageID
        textMessageID = ""
        return [.assistantText(AgentTextBlock(
            text: finished,
            raw: Self.assistantLine(
                blocks: [.object(["type": .string("text"), "text": .string(finished)])],
                messageID: messageID,
                model: context.model,
                usage: usage,
                sessionID: sessionID
            ),
            messageID: messageID,
            model: context.model,
            usage: usage,
            sessionID: sessionID
        ))]
    }

    private mutating func flushThought() -> [AgentEvent] {
        let finished = thought
        thought = ""
        guard !finished.isEmpty else { return [] }
        let messageID = thoughtMessageID
        thoughtMessageID = ""
        return [.thinking(AgentTextBlock(
            text: finished,
            raw: Self.assistantLine(
                blocks: [.object(["type": .string("thinking"), "thinking": .string(finished)])],
                messageID: messageID,
                model: context.model,
                usage: usage,
                sessionID: sessionID
            ),
            messageID: messageID,
            model: context.model,
            usage: usage,
            sessionID: sessionID
        ))]
    }

    private func toolUse(for call: ACPToolCall) -> AgentEvent {
        let input = Self.input(for: call)
        let name = Self.toolName(for: call)
        let block = JSONValue.object([
            "type": .string("tool_use"),
            "id": .string(call.id),
            "name": .string(name),
            "input": input,
        ])
        return .toolUse(AgentToolUse(
            id: call.id,
            name: name,
            input: input,
            raw: Self.assistantLine(
                blocks: [block],
                messageID: call.id,
                model: context.model,
                usage: usage,
                sessionID: sessionID
            ),
            messageID: call.id,
            sessionID: sessionID
        ))
    }

    private func toolResult(for call: ACPToolCall) -> [AgentEvent] {
        let text = call.contentText.isEmpty
            ? (call.rawOutput.stringValue ?? call.rawOutput.prettyPrinted)
            : call.contentText
        let display = text == "null" ? "" : text
        return [.toolResult(AgentToolResult(
            toolUseID: call.id,
            text: display,
            isError: call.isError,
            refusal: Self.wasDeclined(call) ? .denied : nil,
            raw: Self.toolResultLine(
                toolUseID: call.id,
                text: display,
                isError: call.isError,
                refusalKind: Self.wasDeclined(call) ? "user-rejected" : nil,
                sessionID: sessionID
            ),
            sessionID: sessionID
        ))]
    }

    private func merged(_ incoming: ACPToolCall, onto existing: ACPToolCall?) -> ACPToolCall {
        guard let existing else { return incoming }
        return ACPToolCall(
            id: incoming.id.isEmpty ? existing.id : incoming.id,
            title: incoming.title.isEmpty ? existing.title : incoming.title,
            kind: incoming.kind.isEmpty ? existing.kind : incoming.kind,
            status: incoming.status.isEmpty ? existing.status : incoming.status,
            toolName: incoming.toolName.isEmpty ? existing.toolName : incoming.toolName,
            rawInput: incoming.rawInput.objectValue?.isEmpty == false ? incoming.rawInput : existing.rawInput,
            rawOutput: incoming.rawOutput.isNull ? existing.rawOutput : incoming.rawOutput,
            contentText: incoming.contentText.isEmpty ? existing.contentText : incoming.contentText,
            path: incoming.path.isEmpty ? existing.path : incoming.path,
            json: incoming.json
        )
    }

    private func result(for prompt: ACPPromptResult) -> AgentResult {
        let summary = prompt.isError ? prompt.raw["message"]?.stringValue ?? "" : ""
        let subtype = prompt.wasCancelled ? "error_during_execution"
            : prompt.isError ? prompt.stopReason
            : "success"
        return AgentResult(
            usage: usage,
            summary: summary,
            isError: prompt.isError,
            subtype: subtype,
            durationMS: 0,
            numTurns: 1,
            stopReason: prompt.stopReason,
            raw: Self.resultLine(
                subtype: subtype,
                isError: prompt.isError,
                summary: summary,
                durationMS: 0,
                usage: usage,
                model: context.model,
                sessionID: sessionID
            ),
            sessionID: sessionID
        )
    }

    // MARK: - Envelopes

    static func assistantLine(
        blocks: [JSONValue],
        messageID: String,
        model: String,
        usage: AgentUsage,
        sessionID: String
    ) -> Data {
        line(.object([
            "type": .string("assistant"),
            "session_id": .string(sessionID),
            "message": .object([
                "id": .string(messageID),
                "model": .string(model),
                "role": .string("assistant"),
                "content": .array(blocks),
                "usage": encode(usage),
            ]),
        ]))
    }

    static func toolResultLine(
        toolUseID: String,
        text: String,
        isError: Bool,
        refusalKind: String?,
        sessionID: String
    ) -> Data {
        var members: [String: JSONValue] = [
            "type": .string("user"),
            "session_id": .string(sessionID),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(toolUseID),
                    "content": .string(text),
                    "is_error": .bool(isError),
                ])]),
            ]),
        ]
        if let refusalKind {
            members["tool_result_meta"] = .array([.object([
                "id": .string(toolUseID),
                "non_execution_kind": .string(refusalKind),
            ])])
        }
        return line(.object(members))
    }

    static func resultLine(
        subtype: String,
        isError: Bool,
        summary: String,
        durationMS: Int,
        usage: AgentUsage,
        model: String,
        sessionID: String
    ) -> Data {
        var result: [String: JSONValue] = [
            "type": .string("result"),
            "subtype": .string(subtype),
            "is_error": .bool(isError),
            "result": .string(summary),
            "duration_ms": .integer(durationMS),
            "num_turns": .integer(1),
            "session_id": .string(sessionID),
            "usage": encode(usage),
        ]
        if usage.contextTokens > 0 {
            result["modelUsage"] = .object([
                model: .object(["contextWindow": .integer(usage.contextTokens)]),
            ])
        }
        return line(.object(result))
    }

    static func initLine(sessionID: String, context: Context) -> Data {
        line(.object([
            "type": .string("system"),
            "subtype": .string("init"),
            "session_id": .string(sessionID),
            "cwd": .string(context.cwd),
            "model": .string(context.model),
            "permissionMode": .string(context.permissionMode),
            "agent_kind": .string(AgentKind.openCode.rawValue),
        ]))
    }

    static func errorLine(message: String) -> Data {
        line(.object([
            "type": .string("error"),
            "subtype": .string("opencode"),
            "stderr": .string(message),
        ]))
    }

    static func encode(_ usage: AgentUsage) -> JSONValue {
        .object([
            "input_tokens": .integer(usage.inputTokens),
            "output_tokens": .integer(usage.outputTokens),
            "cache_read_input_tokens": .integer(usage.cacheReadTokens),
            "cache_creation_input_tokens": .integer(usage.cacheCreationTokens),
            "output_tokens_details": .object(["thinking_tokens": .integer(usage.thinkingTokens)]),
        ])
    }

    static func line(_ json: JSONValue) -> Data {
        Data(json.compactJSON.utf8)
    }
}

import Foundation

/// OpenCode's permissions, in the vocabulary Bloom's permission prompt already speaks.
///
/// Two halves, because OpenCode splits the subject in two. **Which calls ask** is decided by its
/// config before the process starts, so a Bloom permission mode becomes a `permission` block
/// injected at launch. **What an ask looks like** is ACP's `session/request_permission`, the same
/// request Grok sends, always with three options: `allow_once`, `allow_always`, `reject_once`.
public enum OpenCodePermission {
    /// The config OpenCode is launched with for this mode, or nil when Bloom adds no rule.
    ///
    /// Measured on 2.3.2: everything is allowed by default, and `OPENCODE_CONFIG_CONTENT` is
    /// merged after the user's and the project's config, so these rules are the last match.
    /// Only `edit` and `shell` are named. A `"*"` rule would also outrank what the user denied.
    public static func configContent(for mode: PermissionMode) -> String? {
        let asking: [String]
        switch mode {
        case .auto, .autoReview, .plan: asking = ["edit", "shell"]
        case .acceptEdits: asking = ["shell"]
        case .bypassPermissions: return nil
        }
        let rules = Dictionary(uniqueKeysWithValues: asking.map { ($0, JSONValue.string("ask")) })
        return JSONValue.object(["permission": .object(rules)]).compactJSON
    }

    public static func requestID(_ id: ACPRequestID, sessionID: String, connectionID: UUID) -> String {
        // Server request ids count from zero in every process, so the connection is part of the key.
        "opencode:\(connectionID.uuidString):\(sessionID):\(id.jsonLiteral)"
    }

    public static func ask(for request: ACPPermissionRequest, connectionID: UUID = UUID()) -> PermissionAsk {
        let name = OpenCodeTranslation.toolName(for: request.toolCall)
        let input = OpenCodeTranslation.input(for: request.toolCall)
        let allowsAlways = request.options.contains { $0.kind == "allow_always" }
        let ask = PermissionAsk(
            requestID: requestID(request.id, sessionID: request.sessionID, connectionID: connectionID),
            toolName: name,
            displayName: request.toolCall.title,
            toolUseID: request.toolCall.id,
            input: input,
            summary: request.toolCall.title,
            reason: "",
            reasonType: "permissionPromptTool",
            blockedPath: request.toolCall.path.isEmpty ? nil : request.toolCall.path,
            suggestions: allowsAlways ? [PermissionSuggestion(
                type: "addRules",
                behavior: "allow",
                destination: PermissionDestination.session.rawValue,
                rules: [PermissionRule(toolName: name, ruleContent: ruleContent(for: request.toolCall))],
                raw: .object([:])
            )] : [],
            suppressesAlwaysAllow: !allowsAlways,
            raw: Data()
        )
        return ask.with(raw: envelope(for: ask))
    }

    public static func envelope(for ask: PermissionAsk) -> Data {
        let json = JSONValue.object(omittingNil: [
            "type": .string("control_request"),
            "request_id": .string(ask.requestID),
            "agent_kind": .string(AgentKind.openCode.rawValue),
            "request": .object(omittingNil: [
                "subtype": .string("can_use_tool"),
                "tool_name": .string(ask.toolName),
                "display_name": ask.displayName.isEmpty ? nil : .string(ask.displayName),
                "tool_use_id": .string(ask.toolUseID),
                "input": ask.input,
                "description": .string(ask.summary),
                "decision_reason_type": .string(ask.reasonType),
                "blocked_path": ask.blockedPath.map(JSONValue.string),
                "suppress_always_allow_rule": .bool(ask.suppressesAlwaysAllow),
                "permission_suggestions": .array(ask.suggestions.map { suggestion in
                    .object([
                        "type": .string(suggestion.type),
                        "behavior": .string(suggestion.behavior),
                        "destination": .string(suggestion.destination),
                        "rules": .array(suggestion.rules.map { rule in
                            .object(omittingNil: [
                                "toolName": .string(rule.toolName),
                                "ruleContent": rule.ruleContent.map(JSONValue.string),
                            ])
                        }),
                    ])
                }),
            ]),
        ])
        return Data(json.compactJSON.utf8)
    }

    /// The option to send back for this decision, or nil when the agent offered none that means
    /// it. A missing option is answered as cancelled: an invented `optionId` is how a deny
    /// becomes an allow. OpenCode has one reject, and it ends the turn.
    public static func optionID(for decision: PermissionDecision, in request: ACPPermissionRequest) -> String? {
        let wanted: [String]
        switch decision {
        case .allow(.once), .answer, .approvePlan:
            wanted = ["allow_once"]
        case .allow(.session), .allow(.project):
            wanted = ["allow_always", "allow_once"]
        case .deny:
            wanted = ["reject_once", "reject_always"]
        }
        for kind in wanted {
            if let match = request.options.first(where: { $0.kind == kind }) {
                return match.id
            }
        }
        return request.options.first { decision.isAllow ? $0.isAllow : !$0.isAllow }?.id
    }

    public static func selectedResult(optionID: String) -> JSONValue {
        .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(optionID),
            ]),
        ])
    }

    public static let cancelledResult = JSONValue.object([
        "outcome": .object(["outcome": .string("cancelled")]),
    ])

    private static func ruleContent(for call: ACPToolCall) -> String? {
        let input = OpenCodeTranslation.input(for: call)
        if let command = input["command"]?.stringValue, !command.isEmpty { return command }
        if !call.path.isEmpty { return call.path }
        return nil
    }
}

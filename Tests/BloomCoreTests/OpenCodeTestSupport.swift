import Foundation
@testable import BloomCore

/// Frames in the shapes captured from opencode 2.3.2. See `docs/OPENCODE.md`.
enum OpenCodeFixture {
    static let localModel = "ollama/qwen3.5:4b"
    static let hostedModel = "opencode/hy4-flash-free"

    /// `configOptions` as `session/new` returns them. No effort levels means no effort option.
    static func configOptions(model: String, efforts: [String] = []) -> JSONValue {
        var options: [JSONValue] = [.object([
            "id": .string("model"),
            "category": .string("model"),
            "type": .string("select"),
            "currentValue": .string(model),
            "options": .array([
                .object(["value": .string(localModel), "name": .string(localModel)]),
                .object(["value": .string(hostedModel), "name": .string("opencode/Hy4 flash Free")]),
            ]),
        ])]
        if !efforts.isEmpty {
            options.append(.object([
                "id": .string("effort"),
                "category": .string("thought_level"),
                "type": .string("select"),
                "currentValue": .string("default"),
                "options": .array(efforts.map { .object(["value": .string($0), "name": .string($0.capitalized)]) }),
            ]))
        }
        options.append(.object([
            "id": .string("mode"),
            "category": .string("mode"),
            "currentValue": .string("build"),
            "options": .array([.object(["value": .string("build"), "name": .string("Build")])]),
        ]))
        return .object(["configOptions": .array(options)])
    }

    static func toolUpdate(_ members: [String: JSONValue], isUpdate: Bool) -> ACPSessionUpdate {
        let call = ACPToolCall.decode(.object(members), isUpdate: isUpdate)
        return ACPSessionUpdate(
            sessionID: "ses_1",
            kind: isUpdate ? .toolCallUpdate(call) : .toolCall(call),
            raw: .object(members)
        )
    }

    /// The three options OpenCode always offers, with its own option ids.
    static func permissionRequest(id: Int = 0) -> JSONValue {
        .object([
            "sessionId": .string("ses_1"),
            "toolCall": .object([
                "toolCallId": .string("call_w5isigpu"),
                "name": .string("shell"),
                "title": .string("echo \"two\""),
                "kind": .string("execute"),
                "status": .string("pending"),
                "locations": .array([.object(["path": .string("/tmp/w")])]),
                "rawInput": .object(["command": .string("echo \"two\""), "cwd": .string("/tmp/w")]),
            ]),
            "options": .array([
                .object(["optionId": .string("once"), "kind": .string("allow_once"), "name": .string("Allow once")]),
                .object(["optionId": .string("always"), "kind": .string("allow_always"), "name": .string("Always allow")]),
                .object(["optionId": .string("reject"), "kind": .string("reject_once"), "name": .string("Reject")]),
            ]),
        ])
    }

    static func permissionLine(id: Int = 0) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"session/request_permission\","
            + "\"params\":\(permissionRequest(id: id).compactJSON)}"
    }
}

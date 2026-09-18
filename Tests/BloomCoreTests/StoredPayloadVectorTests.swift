import Foundation
import Testing

@testable import BloomCore

/// What a Codex or Grok turn looks like **after** translation, which is what a client actually
/// reads out of `MessageRecord.payload`.
///
/// `Tests/fixtures/codex-turn.ndjson` and `codex-approval.ndjson` are Codex's own JSON-RPC, and
/// they are the *input* to `CodexTranslation`. Nothing in the repository showed the output, so the
/// first two clients to read the protocol package both had to run the translator in their heads,
/// and one of them concluded it needed three renderers. `Protocol/v1/stored-payloads.json` is that
/// output, written out of the real translator: one renderer, Claude Code's `stream-json` shape,
/// whichever CLI produced the turn.
///
/// It is checked rather than merely written for the same reason `Protocol/v1/vectors.json` is: a
/// translator that changes shape underneath a client should move a file in the same commit and say
/// so here, rather than being found by whoever's transcript stops drawing. Regenerate with
/// `BLOOM_WRITE_VECTORS=1 ./Tools/test-core.sh StoredPayloadVector`, then read the diff.
@Suite struct StoredPayloadVectorTests {
    @Test func theCheckedInPayloadsAreWhatTheTranslatorsProduce() throws {
        let encoded = try Self.encoded()
        let url = try Self.fixtureURL()
        if ProcessInfo.processInfo.environment["BLOOM_WRITE_VECTORS"] == "1" {
            try encoded.write(to: url)
            return
        }
        let stored = try Data(contentsOf: url)
        #expect(String(decoding: stored, as: UTF8.self) == String(decoding: encoded, as: UTF8.self))
    }

    /// The claim the fixture exists to hold, said once in Swift as well, because a JSON file that
    /// drifts is only caught by the test above if somebody knows what to look for.
    @Test func everyStoredCodexRowIsAClaudeShapedLineCarryingItsNativeItem() throws {
        let rows = try Self.codexRows()
        #expect(rows.isEmpty == false)
        for row in rows {
            let json = try #require(JSONValue.parse(row.payload))
            #expect(json["type"]?.stringValue != nil, "a stored row with no stream-json type")
            // Decoded back by the one decoder, which is what a restart does.
            let line = String(decoding: row.payload, as: UTF8.self)
            #expect(AgentEvent.decode(line: line) != nil, "a stored row the transcript decoder cannot read")
        }
        let calls = rows.compactMap { row -> JSONValue? in
            guard row.kind == .toolUse, let json = JSONValue.parse(row.payload) else { return nil }
            return json["message"]?["content"]?.arrayValue?.first
        }
        #expect(calls.isEmpty == false)
        // Codex's own vocabulary, inside Claude's shape, with the native item alongside it.
        #expect(calls.allSatisfy { CodexTranslation.isCodexCall($0["input"] ?? .null) })
        #expect(calls.contains { $0["name"]?.stringValue == "ApplyPatch" })
    }

    // MARK: Building the file

    struct Row {
        var kind: MessageKind
        var refID: String?
        var payload: Data
    }

    static func codexRows() throws -> [Row] {
        var translation = CodexTranslation(context: CodexTranslation.Context(model: "gpt-5.6-sol", cwd: "/tmp/w"))
        // The approval recording rather than the plain turn, because it is the only one with a tool
        // call in it, and a fixture of a transcript with no tool call answers the easy half.
        return try codexEvents("codex-approval.ndjson")
            .flatMap { translation.translate($0) }
            .filter(\.isTranscriptRow)
            .map { Row(kind: $0.kind, refID: $0.refID, payload: $0.raw) }
    }

    /// The stored form of a Codex approval, which is a `control_request` rather than the JSON-RPC
    /// request that arrived, so `permission_asks` holds one vocabulary too.
    static func codexQuestion() throws -> Data {
        let request = try #require(try codexRequests("codex-approval.ndjson").first)
        let item = try codexEvents("codex-approval.ndjson").compactMap { event -> CodexItem? in
            guard case .itemStarted(let started) = event, started.item.id == request.itemID else { return nil }
            return started.item
        }.first
        return CodexPermission.ask(for: request, item: item).raw
    }

    /// Grok has no recorded fixture, so its input is written here: the same four moments as the
    /// Codex turn, in ACP's own spelling, decoded by the real decoder rather than hand-built.
    static func grokRows() throws -> [Row] {
        var translation = GrokTranslation(context: GrokTranslation.Context(
            model: "grok-4.6", cwd: "/tmp/w", permissionMode: "auto"
        ))
        var events: [AgentEvent] = []
        events += translation.translate(.sessionReady(GrokSession(id: "sess-1", currentModelID: "grok-4.6")))
        events += translation.translate(.update(try update([
            "sessionId": .string("sess-1"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("Reading the file.")]),
            ]),
        ])))
        events += translation.translate(.update(try update([
            "sessionId": .string("sess-1"),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("call-1"),
                "title": .string("Read note.txt"),
                "kind": .string("read"),
                "status": .string("pending"),
                "toolName": .string("Read"),
                "rawInput": .object(["path": .string("/tmp/w/note.txt")]),
            ]),
        ])))
        events += translation.translate(.update(try update([
            "sessionId": .string("sess-1"),
            "update": .object([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("call-1"),
                "status": .string("completed"),
                "rawOutput": .object(["output": .string("bloom\n")]),
            ]),
        ])))
        events += translation.translate(.promptCompleted(GrokPromptResult(
            requestID: .number(1), sessionID: "sess-1", stopReason: "end_turn", raw: .object([:])
        )))
        return events.filter(\.isTranscriptRow).map { Row(kind: $0.kind, refID: $0.refID, payload: $0.raw) }
    }

    static func update(_ members: [String: JSONValue]) throws -> GrokSessionUpdate {
        try #require(GrokSessionUpdate.decode(params: .object(members)))
    }

    static func encoded() throws -> Data {
        let document: [String: Any] = [
            "about": "What lands in MessageRecord.payload. Codex and Grok are translated into Claude Code's"
                + " stream-json shape at ingest, before a row is written, so one decoder reads every stored"
                + " row. Tool names stay each backend's own, and Codex's native item travels under"
                + " input.codexItem. Generated from the real translators by StoredPayloadVectorTests;"
                + " the one pinned value is Grok's assistant message id, which is a fresh uuid per block.",
            "codex": [
                "rows": try codexRows().map(json(for:)),
                "question": try object(in: codexQuestion()),
            ],
            "grok": ["rows": try grokRows().map(json(for:)).map(withoutGeneratedMessageID(_:))],
        ]
        var data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Grok mints a fresh UUID for each assistant block, so the id is the one thing here that is
    /// different every run. Pinned to a word, because a fixture nobody can regenerate twice to the
    /// same bytes is a fixture that fails for no reason and gets deleted.
    static func withoutGeneratedMessageID(_ row: [String: Any]) -> [String: Any] {
        var row = row
        guard var payload = row["payload"] as? [String: Any],
              var message = payload["message"] as? [String: Any], message["id"] != nil
        else { return row }
        message["id"] = "<a fresh uuid per assistant block>"
        payload["message"] = message
        row["payload"] = payload
        return row
    }

    static func json(for row: Row) throws -> [String: Any] {
        var member: [String: Any] = ["kind": row.kind.rawValue, "payload": try object(in: row.payload)]
        if let refID = row.refID { member["ref_id"] = refID }
        return member
    }

    static func object(in payload: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: payload)
    }

    /// Beside `vectors.json`, because both answer the same question for a client in another
    /// language and neither is found by somebody reading only the Swift.
    static func fixtureURL() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Protocol/v1")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("vectors.json").path) {
                return candidate.appendingPathComponent("stored-payloads.json")
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

private func codexEvents(_ name: String) throws -> [CodexEvent] {
    try bloomFixtureLines(name).compactMap { line in
        guard case .notification(let notification)? = CodexFrame.decode(line: line) else { return nil }
        return CodexEvent.decode(notification)
    }
}

private func codexRequests(_ name: String) throws -> [CodexApprovalRequest] {
    try bloomFixtureLines(name).compactMap { line in
        guard case .request(let request)? = CodexFrame.decode(line: line) else { return nil }
        return CodexApprovalRequest.decode(request)
    }
}

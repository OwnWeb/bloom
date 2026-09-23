import AsyncHTTPClient
import BloomCore
import Foundation
import NIOCore
import Testing
@testable import BloomRunner

struct ModelGatewayTests {
    private static func grant(
        provider: OpaqueModelGrant.Provider = .openai,
        operation: OpaqueModelGrant.Operation = .openAIResponsesStream,
        model: String = "gpt-5-codex"
    ) -> OpaqueModelGrant {
        OpaqueModelGrant(
            token: String(repeating: "s", count: 64),
            expiresAt: Date().addingTimeInterval(600), revision: 1,
            provider: provider, model: model, operation: operation
        )
    }

    @Test("a local request is bound to its exact grant and strips provider control fields")
    func stripsReservedProviderFields() async throws {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        fake.script("POST", "/model-gateway/streams", .init(
            status: 200, body: "data: {\"type\":\"response.completed\"}\n\n",
            headers: ["Content-Type": "text/event-stream"]
        ))
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client)
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.codex: Self.grant()], baseURL: "http://127.0.0.1:8123"
        )
        let token = try #require(environment[.codex]?["OPENAI_API_KEY"])
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-codex", "stream": true, "store": false, "background": false,
            "input": "Hello",
        ])
        let stream = try await gateway.open(token: token, path: "/v1/responses", body: request)
        _ = try await stream.response.body.collect(upTo: 1_024)
        await gateway.complete(token: token, requestID: stream.requestID)

        let sent = try #require(fake.requests("POST", "/model-gateway/streams").first?.json)
        #expect(sent["version"] as? String == "opaque_model_grant_v1")
        #expect(sent["provider"] as? String == "openai")
        #expect(sent["operation"] as? String == "openai_responses_stream")
        #expect(sent["model"] as? String == "gpt-5-codex")
        let modelRequest = try #require(sent["model_request"] as? [String: Any])
        #expect(modelRequest["input"] as? String == "Hello")
        #expect(modelRequest["model"] as? String == "gpt-5-codex")
        #expect(modelRequest["stream"] == nil)
        #expect(modelRequest["store"] == nil)
        #expect(modelRequest["background"] == nil)
        #expect(fake.requests("POST", "/model-gateway/streams").first?.proof["version"] == "1")
        await gateway.shutdown()
    }

    @Test("Claude's beta names reach runbloom.app, so a request using them is not refused upstream")
    func forwardsAnthropicBetas() async throws {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        fake.script("POST", "/model-gateway/streams", .init(
            status: 200, body: "data: {}\n\n", headers: ["Content-Type": "text/event-stream"]
        ))
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client)
        let grant = Self.grant(provider: .anthropic, operation: .anthropicMessagesStream, model: "claude-opus-5")
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.claudeCode: grant], baseURL: "http://127.0.0.1:8123"
        )
        let token = try #require(environment[.claudeCode]?["ANTHROPIC_API_KEY"])
        let request = try JSONSerialization.data(withJSONObject: [
            "messages": [], "context_management": [:] as [String: Any],
        ])
        let stream = try await gateway.open(
            token: token, path: "/v1/messages", body: request,
            betas: ["claude-code-20250219, context-management-2025-06-27", "context-management-2025-06-27"]
        )
        _ = try await stream.response.body.collect(upTo: 1_024)
        await gateway.complete(token: token, requestID: stream.requestID)

        let sent = try #require(fake.requests("POST", "/model-gateway/streams").first?.json)
        #expect(sent["anthropic_beta"] as? [String] == ["claude-code-20250219", "context-management-2025-06-27"])
        await gateway.shutdown()
    }

    @Test("the model Claude resolves from its grant is accepted, and nothing outside it")
    func acceptsResolvedModels() {
        #expect(ModelGateway.allows(requested: "claude-opus-5", granted: "claude-opus-5[1m]"))
        #expect(ModelGateway.allows(requested: "claude-opus-5", granted: "opus[1m]"))
        #expect(ModelGateway.allows(requested: "gpt-5-codex", granted: "gpt-5-codex"))
        #expect(!ModelGateway.allows(requested: "claude-sonnet-4-5", granted: "opus[1m]"))
        #expect(!ModelGateway.allows(requested: "claude-opus-4-1", granted: "claude-opus-5[1m]"))
        #expect(!ModelGateway.allows(requested: "claude-opus-5[1m]", granted: "claude-opus-5[1m]"))
    }

    @Test("a beta name that is not a plain token, or one sent for another provider, is refused")
    func refusesUnsafeBetas() throws {
        #expect(try ModelGateway.anthropicBetas([], provider: .openai).isEmpty)
        #expect(throws: ModelGateway.Refusal.self) {
            try ModelGateway.anthropicBetas(["x\r\ninjected: 1"], provider: .anthropic)
        }
        #expect(throws: ModelGateway.Refusal.self) {
            try ModelGateway.anthropicBetas(["files-api-2025-04-14"], provider: .openai)
        }
    }

    @Test("a model override is refused before any upstream request")
    func refusesModelOverride() async throws {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client)
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.codex: Self.grant()], baseURL: "http://127.0.0.1:8123"
        )
        let token = try #require(environment[.codex]?["OPENAI_API_KEY"])
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.6-pro", "stream": true, "input": "Hello",
        ])
        await #expect(throws: ModelGateway.Refusal.self) {
            _ = try await gateway.open(token: token, path: "/v1/responses", body: request)
        }
        #expect(fake.requests("POST", "/model-gateway/streams").isEmpty)
        await gateway.shutdown()
    }

    @Test("ending a turn revokes its local credential and cancels active streams")
    func revokeCancelsActiveStreams() async throws {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        fake.script("POST", "/model-gateway/streams", .init(
            status: 200, body: "data: {}\n\n", headers: ["Content-Type": "text/event-stream"]
        ))
        let fixedID = UUID(uuidString: "19c558bd-8783-4059-85e0-878d48ec19c8")!
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client, identifier: { fixedID })
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.codex: Self.grant()], baseURL: "http://127.0.0.1:8123"
        )
        let token = try #require(environment[.codex]?["OPENAI_API_KEY"])
        let request = try JSONSerialization.data(withJSONObject: ["input": "Hello"])
        _ = try await gateway.open(token: token, path: "/v1/responses", body: request)
        await gateway.revoke(turnID: "turn-1")

        #expect(fake.requests("DELETE", "/model-gateway/requests/\(fixedID.uuidString.lowercased())").count == 1)
        await #expect(throws: ModelGateway.Refusal.self) {
            _ = try await gateway.open(token: token, path: "/v1/responses", body: request)
        }
    }

    /// One model request through the loopback server, with runbloom.app answering `upstream`:
    /// what the agent would receive.
    private static func relay(
        _ upstream: FakeControlServer.Scripted
    ) async throws -> (status: Int, headers: [(name: String, value: String)], body: Data) {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        fake.script("POST", "/model-gateway/streams", upstream)
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client)
        let server = try await ModelGatewayServer.start(gateway: gateway)
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.codex: Self.grant()], baseURL: server.baseURL
        )
        let token = try #require(environment[.codex]?["OPENAI_API_KEY"])
        var request = HTTPClientRequest(url: server.baseURL + "/v1/responses")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.body = .bytes(ByteBuffer(string: #"{"model":"gpt-5-codex","stream":true,"input":"Hello"}"#))
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(60))
        let body = try await response.body.collect(upTo: 1 << 20)
        await gateway.shutdown()
        await server.stop()
        return (
            Int(response.status.code), response.headers.map { ($0.name, $0.value) },
            Data(buffer: body)
        )
    }

    private static func values(
        _ name: String, in headers: [(name: String, value: String)]
    ) -> [String] {
        headers.filter { $0.name.lowercased() == name.lowercased() }.map(\.value)
    }

    @Test("a provider's own 400 reaches the agent as that 400, with its body and only the allowed headers")
    func relaysMarkedProviderError() async throws {
        let providerBody = #"{"error":{"type":"invalid_request_error","message":"input is too long"}}"#
        let (status, headers, body) = try await Self.relay(.init(
            status: 400, body: providerBody,
            headers: [
                "X-Bloom-Upstream-Status": "400", "x-request-id": "req_123",
                "x-ratelimit-remaining-requests": "41", "Set-Cookie": "session=stolen",
                "Location": "https://example.com", "X-Injected": "yes",
            ]
        ))
        #expect(status == 400)
        #expect(String(decoding: body, as: UTF8.self) == providerBody)
        #expect(Self.values("x-request-id", in: headers) == ["req_123"])
        #expect(Self.values("x-ratelimit-remaining-requests", in: headers) == ["41"])
        #expect(Self.values("Set-Cookie", in: headers).isEmpty)
        #expect(Self.values("Location", in: headers).isEmpty)
        #expect(Self.values("X-Injected", in: headers).isEmpty)
        #expect(Self.values("X-Bloom-Upstream-Status", in: headers).isEmpty)
        #expect(Self.values("Retry-After", in: headers).isEmpty)
    }

    @Test("a provider's overload keeps its own Retry-After rather than the gateway's 30 seconds")
    func relaysMarkedOverload() async throws {
        let (status, headers, _) = try await Self.relay(.init(
            status: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            headers: ["X-Bloom-Upstream-Status": "529", "retry-after": "2"]
        ))
        #expect(status == 529)
        #expect(Self.values("Retry-After", in: headers) == ["2"])
    }

    @Test("a provider's 503 without Retry-After is left to the agent's own backoff, not given 30 seconds")
    func relaysMarkedUnavailableWithoutDelay() async throws {
        let (status, headers, _) = try await Self.relay(.init(
            status: 503, body: #"{"error":{"type":"server_error","message":"Unavailable"}}"#,
            headers: ["X-Bloom-Upstream-Status": "503"]
        ))
        #expect(status == 503)
        #expect(Self.values("Retry-After", in: headers).isEmpty)
    }

    @Test("runbloom.app's own 503, unmarked, still becomes the gateway's 503 with 30 seconds")
    func keepsUnmarkedUnavailable() async throws {
        let (status, headers, body) = try await Self.relay(.json(503, [
            "code": "model_provider_unavailable", "message": "The model provider is unavailable.",
        ]))
        #expect(status == 503)
        #expect(Self.values("Retry-After", in: headers) == ["30"])
        let error = try #require(
            (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        )
        #expect(error["type"] as? String == "model_gateway_error")
    }

    @Test("runbloom.app's own stream limit, unmarked, is the gateway's 429 with its Retry-After and nothing else")
    func keepsUnmarkedLimit() async throws {
        let (status, headers, body) = try await Self.relay(.init(
            status: 429, body: #"{"code":"too_many_requests","message":"Slow down."}"#,
            headers: ["Retry-After": "7", "x-ratelimit-remaining-requests": "0"]
        ))
        #expect(status == 429)
        #expect(Self.values("Retry-After", in: headers) == ["7"])
        #expect(Self.values("x-ratelimit-remaining-requests", in: headers).isEmpty)
        let error = try #require(
            (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        )
        #expect(error["message"] as? String == "Too many model requests.")
    }
}

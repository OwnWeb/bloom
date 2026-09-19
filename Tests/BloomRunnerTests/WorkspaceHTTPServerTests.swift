import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing
@testable import BloomCore
@testable import BloomRunner

@Suite("bloom-runner's HTTP front")
struct WorkspaceHTTPServerTests {
    struct Fixture {
        let issuer: TestTokenIssuer
        let runtime: WorkspaceRuntime
        let server: WorkspaceHTTPServer
        let control: RecordingControl
        let session: Session
        let store: Store
        let verifier: TokenVerifier
    }

    func fixture() async throws -> Fixture {
        let issuer = TestTokenIssuer()
        let store = try Store(path: NSTemporaryDirectory() + "bloom-runner-http-\(UUID().uuidString).sqlite")
        let path = NSTemporaryDirectory() + "bloom-runner-worktree-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let workspace = try await RemoteMachineWorkspace.ensure(store: store, id: issuer.workspaceID, name: "Queue retries",
                                                                 repository: "spatie/bloom", path: path, branch: "queue-retries", baseBranch: "main")
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let runtime = WorkspaceRuntime(store: store, workspaceID: workspace.id, gate: UngatedTurns(),
                                       makeRunner: { _, _, _, _, _ in NeverRunner() }, installedAgents: { [.claudeCode] }, models: { _ in [] })
        try await runtime.start()
        let control = RecordingControl()
        let verifier = TokenVerifier(issuer: issuer.issuer, workspaceID: issuer.workspaceID, keys: issuer.keySet())
        let server = WorkspaceHTTPServer(dependencies: .init(
            runtime: runtime, verifier: verifier, gate: UngatedTurns(), control: control, store: store,
            allowedOrigins: ["https://runbloom.app"], version: "1.2.3"
        ))
        return Fixture(issuer: issuer, runtime: runtime, server: server, control: control, session: session, store: store,
                       verifier: verifier)
    }

    static func bearer(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    static func body(_ request: CommandRequest) throws -> ByteBuffer {
        ByteBuffer(bytes: try WireJSON.encode(request))
    }

    @Test("health answers without a token and says only the version")
    func health() async throws {
        let fixture = try await fixture()
        try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == #"{"version":"1.2.3"}"#)
            }
        }
        await fixture.runtime.shutdown()
    }

    @Test("a command needs a session token, and a preview or control token is not one")
    func commandsNeedASessionToken() async throws {
        let fixture = try await fixture()
        let request = try Self.body(CommandRequest(.workspace))
        try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: [.contentType: "application/json"], body: request) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains(#""code":"unauthenticated""#))
            }
            for token in [fixture.issuer.preview(), fixture.issuer.control()] {
                try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(token), body: request) { response in
                    #expect(response.status == .unauthorized)
                }
            }
            try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(fixture.issuer.session()), body: request) { response in
                #expect(response.status == .ok)
                let reply = try WireJSON.decode(CommandReply.self, from: Data(buffer: response.body))
                guard case .workspace(let snapshot) = reply.result else { Issue.record("No snapshot: \(String(buffer: response.body))"); return }
                #expect(snapshot.chats.map(\.id) == [fixture.session.id.rawValue])
            }
        }
        await fixture.runtime.shutdown()
    }

    @Test("the author of a prompt is the token's subject, whatever the body says")
    func authorsComeFromTheToken() async throws {
        let fixture = try await fixture()
        let token = fixture.issuer.session(userID: "01k5a7c2b0z9y8x7w6v5t4s3rz", name: "Seb")
        let request = try Self.body(CommandRequest(.send(chatID: fixture.session.id.rawValue, text: "Hello")))
        let promptID = try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(token), body: request) { response -> String? in
                let reply = try WireJSON.decode(CommandReply.self, from: Data(buffer: response.body))
                guard case .queued(let id) = reply.result else { Issue.record("Not queued: \(String(buffer: response.body))"); return nil }
                return id
            }
        }
        // Looked up by the id the reply gave rather than read off the queue, which the drain may
        // already have emptied.
        let delivery = try await fixture.store.delivery(id: DeliveryID(try #require(promptID)))
        #expect(delivery?.author == MessageAuthor(userID: "01k5a7c2b0z9y8x7w6v5t4s3rz", name: "Seb"))
        await fixture.runtime.shutdown()
    }

    @Test("a body that is not an envelope is a 400 with a code")
    func malformedBodies() async throws {
        let fixture = try await fixture()
        try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/v1/rpc", method: .post, headers: Self.bearer(fixture.issuer.session()),
                                     body: ByteBuffer(string: #"{"operation":{"kind":"catalogue"}}"#)) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains(#""code":"invalid_request""#))
            }
        }
        await fixture.runtime.shutdown()
    }

    @Test("preflight is answered for pinned origins only, and never with credentials")
    func cors() async throws {
        let fixture = try await fixture()
        try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/v1/rpc", method: .options,
                                     headers: [.origin: "https://runbloom.app", .accessControlRequestMethod: "POST"]) { response in
                #expect(response.status == .noContent)
                #expect(response.headers[.accessControlAllowOrigin] == "https://runbloom.app")
                #expect(response.headers[.accessControlAllowHeaders]?.contains("Authorization") == true)
                #expect(response.headers[.accessControlAllowCredentials] == nil)
                #expect(response.headers[.accessControlMaxAge] == "600")
            }
            try await client.execute(uri: "/_bloom/v1/rpc", method: .options, headers: [.origin: "https://evil.example"]) { response in
                #expect(response.status == .forbidden)
                #expect(response.headers[.accessControlAllowOrigin] == nil)
            }
            try await client.execute(uri: "/_bloom/health", method: .get, headers: [.origin: "https://runbloom.app"]) { response in
                #expect(response.headers[.accessControlAllowOrigin] == nil, "Only /_bloom/v1 answers cross-origin")
            }
        }
        await fixture.runtime.shutdown()
    }

    @Test("control calls take a control token once, and nothing else")
    func controlCalls() async throws {
        let fixture = try await fixture()
        let control = fixture.issuer.control()
        try await fixture.server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/v1/control/revoke", method: .post, headers: Self.bearer(fixture.issuer.session()),
                                     body: ByteBuffer(string: #"{"user_id":"01k5a7c2b0z9y8x7w6v5t4s3rq"}"#)) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: "/_bloom/v1/control/revoke", method: .post, headers: Self.bearer(control),
                                     body: ByteBuffer(string: #"{"user_id":"01k5a7c2b0z9y8x7w6v5t4s3rq"}"#)) { response in
                #expect(response.status == .accepted)
            }
            try await client.execute(uri: "/_bloom/v1/control/revoke", method: .post, headers: Self.bearer(control),
                                     body: ByteBuffer(string: #"{"user_id":"01k5a7c2b0z9y8x7w6v5t4s3rq"}"#)) { response in
                #expect(response.status == .unauthorized, "A control token is refused the second time")
            }
            try await client.execute(uri: "/_bloom/v1/control/update", method: .post, headers: Self.bearer(fixture.issuer.control()),
                                     body: ByteBuffer(string: #"{"version":"1.4.0","sha256":"abc","tag":"runner-v1.4.0"}"#)) { response in
                #expect(response.status == .accepted)
            }
            try await client.execute(uri: "/_bloom/v1/control/update", method: .post, headers: Self.bearer(fixture.issuer.control()),
                                     body: ByteBuffer(string: #"{"version":"1.5.0","sha256":"def","tag":"runner-v1.5.0","download_url":"https://objects.githubusercontent.com/a?sig=1"}"#)) { response in
                #expect(response.status == .accepted)
            }
            try await client.execute(uri: "/_bloom/v1/control/stop", method: .post, headers: Self.bearer(fixture.issuer.control()),
                                     body: ByteBuffer(string: #"{}"#)) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(uri: "/_bloom/v1/control/revoke", method: .post, headers: Self.bearer(fixture.issuer.control()),
                                     body: ByteBuffer(string: #"{"user_ids":["01k5a7c2b0z9y8x7w6v5t4s3r1","01k5a7c2b0z9y8x7w6v5t4s3r2"]}"#)) { response in
                #expect(response.status == .accepted)
            }
            try await client.execute(uri: "/_bloom/v1/control/revoke", method: .post, headers: Self.bearer(fixture.issuer.control()),
                                     body: ByteBuffer(string: #"{"user_ids":[]}"#)) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(uri: "/_bloom/v1/control/secret-rotated", method: .post, headers: Self.bearer(fixture.issuer.control()),
                                     body: ByteBuffer(string: #"{}"#)) { response in
                #expect(response.status == .accepted)
            }
        }
        #expect(fixture.control.calls.withLock { $0 }.contains("revoke 01k5a7c2b0z9y8x7w6v5t4s3rq"))
        #expect(fixture.control.calls.withLock { $0 }.contains("update 1.4.0 abc runner-v1.4.0"))
        #expect(fixture.control.calls.withLock { $0 }.contains("update 1.5.0 def runner-v1.5.0 https://objects.githubusercontent.com/a?sig=1"))
        #expect(fixture.control.calls.withLock { $0 }.contains("revoke 01k5a7c2b0z9y8x7w6v5t4s3r1"))
        #expect(fixture.control.calls.withLock { $0 }.contains("revoke 01k5a7c2b0z9y8x7w6v5t4s3r2"))
        #expect(fixture.control.calls.withLock { $0 }.contains("secret-rotated"))
        await fixture.runtime.shutdown()
    }

    @Test("entering the preview sets a host-only cookie once, and the cookie is what the check reads")
    func previewExchange() async throws {
        let fixture = try await fixture()
        let token = fixture.issuer.preview()
        try await fixture.server.application(port: 0).test(.router) { client in
            let cookie = try await client.execute(uri: "/_bloom/preview/enter?token=\(token)", method: .get) { response -> String in
                #expect(response.status == .seeOther)
                #expect(response.headers[.location] == "/")
                let setCookie = response.headers[.setCookie] ?? ""
                #expect(setCookie.hasPrefix("__Host-bloom-preview="))
                #expect(setCookie.contains("HttpOnly") && setCookie.contains("Secure") && setCookie.contains("SameSite=Lax"))
                #expect(setCookie.contains("Max-Age=3600"), "an hour, which runbloom.app's revoke retry is sized to")
                return String(setCookie.split(separator: ";")[0])
            }
            try await client.execute(uri: "/_bloom/preview/enter?token=\(token)", method: .get) { response in
                #expect(response.status == .unauthorized, "A preview token is single use")
            }
            try await client.execute(uri: "/_bloom/preview/check", method: .get, headers: [.cookie: "theme=dark; \(cookie)"]) { response in
                #expect(response.status == .noContent)
            }
            try await client.execute(uri: "/_bloom/preview/check", method: .get, headers: [.cookie: "__Host-bloom-preview=forged"]) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: "/_bloom/preview/enter?token=\(fixture.issuer.session())", method: .get) { response in
                #expect(response.status == .unauthorized, "A session token does not open the preview")
            }
            let share = fixture.issuer.preview(subject: "share:01k5a7c2b0z9y8x7w6v5t4s3rs")
            try await client.execute(uri: "/_bloom/preview/enter?token=\(share)", method: .get) { response in
                #expect(response.headers[.setCookie]?.contains("Max-Age=3600") == true, "A share link's cookie lasts an hour")
            }
        }
        await fixture.runtime.shutdown()
    }

    @Test("the page behind a preview that shows nothing names the services, and only to somebody let in")
    func previewUnavailable() async throws {
        let fixture = try await fixture()
        let verifier = TokenVerifier(issuer: fixture.issuer.issuer, workspaceID: fixture.issuer.workspaceID, keys: fixture.issuer.keySet())
        let server = WorkspaceHTTPServer(dependencies: .init(
            runtime: fixture.runtime, verifier: verifier, gate: UngatedTurns(), control: fixture.control, store: fixture.store,
            allowedOrigins: [], version: "1.2.3",
            services: { [.init(name: "vite", state: .crashed, restarts: 3, message: "Exited with status 1. Starting again in 5 s.")] }
        ))
        try await server.application(port: 0).test(.router) { client in
            let cookie = try await client.execute(uri: "/_bloom/preview/enter?token=\(fixture.issuer.preview())", method: .get) { response -> String in
                String((response.headers[.setCookie] ?? "").split(separator: ";")[0])
            }
            try await client.execute(uri: "/_bloom/preview/unavailable", method: .get, headers: [.cookie: cookie]) { response in
                let text = String(buffer: response.body)
                #expect(response.status == .badGateway)
                #expect(text.contains("vite: crashed after 3 restarts. Exited with status 1."))
            }
            try await client.execute(uri: "/_bloom/preview/unavailable", method: .get) { response in
                let text = String(buffer: response.body)
                #expect(response.status == .badGateway)
                #expect(!text.contains("vite"), "Without the cookie it names nothing of the project")
            }
        }
        await fixture.runtime.shutdown()
    }

    @Test("the event stream sends SSE frames with the stream's id in a header, and ends when the machine sleeps")
    func eventStream() async throws {
        let fixture = try await fixture()
        let runtime = fixture.runtime
        try await fixture.server.application(port: 0).test(.router) { client in
            // Waits for the stream to be subscribed rather than for a fixed time, because on a
            // loaded CI runner 300 ms once passed before it was, and the sleep went to nobody.
            let sleeper = Task {
                while await runtime.events.count == 0 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                await runtime.announceSleep()
            }
            try await client.execute(uri: "/_bloom/v1/events", method: .get, headers: Self.bearer(fixture.issuer.session())) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/event-stream")
                #expect(response.headers[EventStreamRoute.streamIDHeader] != nil)
                let text = String(buffer: response.body)
                #expect(text.contains("event: chat\n"))
                #expect(text.contains("event: queue\n"))
                #expect(text.hasSuffix("event: sleeping\ndata: {\"kind\":\"sleeping\"}\n\n"))
            }
            _ = try await sleeper.value
        }
        await fixture.runtime.shutdown()
    }

    @Test("the local git credential route pushes only under a turn that is live here")
    func gitCredentialTurns() async throws {
        let fixture = try await fixture()
        let asked = Mutex<[String]>([])
        let verifier = TokenVerifier(issuer: fixture.issuer.issuer, workspaceID: fixture.issuer.workspaceID, keys: fixture.issuer.keySet())
        let server = WorkspaceHTTPServer(dependencies: .init(
            runtime: fixture.runtime, verifier: verifier, gate: UngatedTurns(), control: fixture.control, store: fixture.store,
            allowedOrigins: [], version: "1.2.3",
            gitCredentials: .init(secret: "local", repository: "spatie/bloom") { _, operation, turn in
                asked.withLock { $0.append("\(operation.rawValue) \(turn ?? "-")") }
                return RunbloomGitCredential(token: "t", expiresAt: Date(), username: "x-access-token")
            }
        ))
        let headers: HTTPFields = [GitCredentialRoute.secretHeader: "local", .contentType: "application/json"]
        try await server.application(port: 0).test(.router) { client in
            try await client.execute(uri: "/_bloom/local/git-credentials", method: .post, headers: headers,
                                     body: ByteBuffer(string: #"{"repository":"spatie/bloom","turn_id":"somebody-elses-turn"}"#)) { response in
                #expect(response.status == .forbidden, "A turn id nothing here is publishing under is refused")
            }
            try await client.execute(uri: "/_bloom/local/git-credentials", method: .post, headers: headers,
                                     body: ByteBuffer(string: #"{"repository":"spatie/bloom","terminal":"not-connected"}"#)) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/_bloom/local/git-credentials", method: .post, headers: headers,
                                     body: ByteBuffer(string: #"{"repository":"spatie/other"}"#)) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(asked.withLock { $0 } == ["read -"], "A terminal with no open connection only reads")
        await fixture.runtime.shutdown()
    }

    /// M1 in the review of 19 September 2026: every process can read the local secret, so a named
    /// chat, terminal or turn counts only when the caller descends from it.
    @Test("a write token goes only to a caller that descends from the chat, terminal or push it names")
    func gitCredentialsFollowTheCaller() async throws {
        let fixture = try await fixture()
        let asked = Mutex<[String]>([])
        let origin = Mutex<LocalOrigin?>(nil)
        let verifier = TokenVerifier(issuer: fixture.issuer.issuer, workspaceID: fixture.issuer.workspaceID, keys: fixture.issuer.keySet())
        var credentials = WorkspaceHTTPServer.GitCredentials(secret: "local", repository: "spatie/bloom") { _, operation, turn in
            asked.withLock { $0.append("\(operation.rawValue) \(turn ?? "-")") }
            return RunbloomGitCredential(token: "t", expiresAt: Date(), username: "x-access-token")
        }
        credentials.origin = { _ in origin.withLock { $0 } }
        let server = WorkspaceHTTPServer(dependencies: .init(
            runtime: fixture.runtime, verifier: verifier, gate: UngatedTurns(), control: fixture.control, store: fixture.store,
            allowedOrigins: [], version: "1.2.3", gitCredentials: credentials
        ))
        let headers: HTTPFields = [GitCredentialRoute.secretHeader: "local", .contentType: "application/json"]
        let chat = fixture.session.id.rawValue
        try await server.application(port: 0).test(.router) { client in
            // A setup script or a service: descends from nothing the Runner started for a person.
            origin.withLock { $0 = LocalOrigin() }
            try await client.execute(uri: "/_bloom/local/git-credentials", method: .post, headers: headers,
                                     body: ByteBuffer(string: #"{"repository":"spatie/bloom","chat_id":"\#(chat)"}"#)) { response in
                #expect(response.status == .ok)
            }
            // Another chat's agent naming this one.
            origin.withLock { $0 = LocalOrigin(chatID: SessionID("another-chat")) }
            try await client.execute(uri: "/_bloom/local/git-credentials", method: .post, headers: headers,
                                     body: ByteBuffer(string: #"{"repository":"spatie/bloom","chat_id":"\#(chat)"}"#)) { response in
                #expect(response.status == .ok)
            }
            // A shell in somebody else's terminal naming this one.
            origin.withLock { $0 = LocalOrigin(terminal: "theirs") }
            try await client.execute(uri: "/_bloom/local/git-credentials", method: .post, headers: headers,
                                     body: ByteBuffer(string: #"{"repository":"spatie/bloom","terminal":"mine"}"#)) { response in
                #expect(response.status == .ok)
            }
            // Nobody the kernel can vouch for, naming a turn.
            origin.withLock { $0 = nil }
            try await client.execute(uri: "/_bloom/local/git-credentials", method: .post, headers: headers,
                                     body: ByteBuffer(string: #"{"repository":"spatie/bloom","turn_id":"a-turn"}"#)) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(asked.withLock { $0 } == ["read -", "read -", "read -"], "every one of them only reads")
        await fixture.runtime.shutdown()
    }

    @Test("an SSE frame keeps its JSON on one line and carries the cursor as its id")
    func frames() throws {
        let message = MessageRecord(cursor: 42, chatID: "chat", seq: 1, kind: "user", payload: .string("line one\nline two"), createdAt: Date(timeIntervalSince1970: 0))
        let frame = EventStreamRoute.frame(.message(message))
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "event: message")
        #expect(lines[1] == "id: 42")
        #expect(lines[2].hasPrefix("data: {"))
        #expect(lines.count == 5, "event, id, data, and the blank line that ends the frame")
    }
}

final class RecordingControl: MachineControl {
    let calls = Mutex<[String]>([])
    func stop(limit: String) async { calls.withLock { $0.append("stop \(limit)") } }
    func limitsCleared() async { calls.withLock { $0.append("limits-cleared") } }
    func revoke(userID: String) async { calls.withLock { $0.append("revoke \(userID)") } }
    func update(version: String, sha256: String, tag: String?, downloadURL: String?) async throws {
        calls.withLock { $0.append("update \(version) \(sha256) \(tag ?? "-")" + (downloadURL.map { " \($0)" } ?? "")) }
    }
    func environmentChanged() async { calls.withLock { $0.append("environment") } }
    func secretRotated() async { calls.withLock { $0.append("secret-rotated") } }
    func shared() async { calls.withLock { $0.append("shared") } }
}

/// A runner for tests that never get as far as a turn.
actor NeverRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.claudeCode
    nonisolated var events: AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    nonisolated var presentationFeed: AgentPresentationFeed? { nil }
    var isProcessAlive: Bool { false }
    func send(_ text: String, recording: Data?) async throws {}
    func sendDelivery(_ delivery: Delivery) async throws {}
    nonisolated func cancelNow() {}
    nonisolated func terminateNow() {}
    func answer(requestID: String, decision: PermissionDecision) async {}
}

/// The repository went private on 19 September 2026, so an update downloads from a signed URL
/// runbloom.app resolves, and only from where GitHub serves release assets.
@Suite("Where an update downloads from")
struct MachineUpdateDownloadTests {
    @Test("a signed asset URL is taken, and anything else is refused without repeating it")
    func onlyAssetHosts() throws {
        #expect(try MachineUpdate.checkedDownloadURL(nil) == nil)
        let signed = "https://release-assets.githubusercontent.com/github-production-release-asset/1?sig=x"
        #expect(try MachineUpdate.checkedDownloadURL(signed) == signed)
        for refused in [
            "http://objects.githubusercontent.com/a", "https://github.com/spatie/bloom/releases/download/x",
            "https://evil.example/objects.githubusercontent.com", "https://user:pass@objects.githubusercontent.com/a",
            "file:///tmp/archive.tar.gz",
        ] {
            do {
                _ = try MachineUpdate.checkedDownloadURL(refused)
                Issue.record("\(refused) was accepted")
            } catch let failure as RemoteFailure {
                #expect(!failure.wire.message.contains(refused), "a bearer URL is never repeated")
            }
        }
    }
}

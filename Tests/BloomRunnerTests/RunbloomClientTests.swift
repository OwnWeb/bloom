import AsyncHTTPClient
import BloomCore
import Foundation
import NIOCore
import Synchronization
import Testing
@testable import BloomRunner

struct RunbloomClientTests {
    private static func withFake(_ body: (FakeControlServer, RunbloomClient) async throws -> Void) async throws {
        let fake = try await FakeControlServer.start()
        let client = RunbloomClient(baseURL: fake.baseURL + "/", workspaceID: fake.workspaceID, secret: fake.secret, http: .shared)
        do {
            try await body(fake, client)
        } catch {
            await fake.stop()
            throw error
        }
        await fake.stop()
    }

    @Test func summaryAndUsageArePostedAsGivenWithTheSecret() async throws {
        try await Self.withFake { fake, client in
            let summary = Data(#"{"revision":42}"#.utf8)
            let usage = Data(#"{"machine_boot_id":"boot","sequence":1}"#.utf8)
            try await client.postSummary(summary)
            try await client.postUsage(usage)

            let posted = fake.requests
            #expect(posted.map(\.method) == ["POST", "POST"])
            #expect(posted.map(\.path) == ["/summary", "/usage"])
            #expect(posted.allSatisfy { $0.authorization == "Bearer secret-for-tests" })
            #expect(posted.allSatisfy { $0.contentType == "application/json" })
            #expect(posted.map(\.body) == [summary, usage])
        }
    }

    @Test func environmentIsRead() async throws {
        try await Self.withFake { fake, client in
            fake.environment = ["APP_ENV": "local", "EMPTY": ""]
            #expect(try await client.environment() == ["APP_ENV": "local", "EMPTY": ""])
            let request = try #require(fake.requests.first)
            #expect(request.method == "GET")
            #expect(request.path == "/environment")
            #expect(request.body.isEmpty)
        }
    }

    /// The body runbloom.app actually answers with, written out rather than re-encoded, because
    /// what is being tested is that the two sides agree about the shape.
    @Test func membersAreReadWithTheirHandles() async throws {
        try await Self.withFake { fake, client in
            fake.membersBody = """
            {"members": [
              {"user_id": "01k5bx7j9d3v2r8q6m4n0p1s2t", "name": "Freek Van der Herten", "handle": "freek"},
              {"user_id": "01k5bx7j9d3v2r8q6m4n0p1s2u", "name": "Sebastian De Deyne", "handle": "sebdd"}
            ]}
            """
            let members = try await client.members()

            #expect(members.map(\.handle) == ["freek", "sebdd"])
            #expect(members.first?.userID == "01k5bx7j9d3v2r8q6m4n0p1s2t")
            #expect(members.first?.name == "Freek Van der Herten")
            let request = try #require(fake.requests.first)
            #expect(request.method == "GET")
            #expect(request.path == "/members")
        }
    }

    /// A team with nobody in it yet, and a machine that has never asked, must not look the same.
    @Test func anEmptyMemberListIsStillAnAnswer() async throws {
        try await Self.withFake { fake, client in
            fake.membersBody = #"{"members": []}"#
            let members = try await client.members()
            #expect(members.isEmpty)
        }
    }

    @Test func aTurnIsRegisteredWithTheTokenChatAndAgent() async throws {
        try await Self.withFake { fake, client in
            let turn = try await client.registerTurn(kind: .turn, chatID: "chat-1", agent: .claudeCode, sessionToken: "jwt.for.prompter")
            #expect(turn == FakeControlServer.turnID(1))

            let json = try #require(fake.requests("POST", "/turns").first?.json)
            #expect(json["kind"] as? String == "turn")
            #expect(json["session_token"] as? String == "jwt.for.prompter")
            #expect(json["chat_id"] as? String == "chat-1")
            #expect(json["agent"] as? String == "claude")
        }
    }

    @Test func aTerminalIsRegisteredWithNullChatAndAgent() async throws {
        try await Self.withFake { fake, client in
            _ = try await client.registerTurn(kind: .terminal, chatID: nil, agent: nil, sessionToken: "jwt")
            let json = try #require(fake.requests("POST", "/turns").first?.json)
            #expect(json["kind"] as? String == "terminal")
            #expect(json["chat_id"] is NSNull)
            #expect(json["agent"] is NSNull)
        }
    }

    @Test func startingDecodesKeysByAgentAndSkipsAgentsItDoesNotKnow() async throws {
        try await Self.withFake { fake, client in
            fake.setStart(turnID: "01jturnstart", response: .grant(
                keys: [
                    "claude": ("sk-ant-1", "hash-1", "team"),
                    "codex": ("sk-openai", "hash-2", "personal"),
                    "someday": ("x", "y", "team"),
                ],
                environment: ["GREETING": "hello"]
            ))
            let start = try await client.startTurn("01jturnstart")

            #expect(start.agentKeys[.claudeCode] == RemoteAgentKey(key: "sk-ant-1", identity: "hash-1", source: "team"))
            #expect(start.agentKeys[.codex] == RemoteAgentKey(key: "sk-openai", identity: "hash-2", source: "personal"))
            #expect(start.agentKeys.count == 2)
            #expect(start.environment == ["GREETING": "hello"])
            #expect(!start.description.contains("sk-ant-1"))

            let request = try #require(fake.requests.first)
            #expect(request.method == "POST")
            #expect(request.path == "/turns/01jturnstart/start")
            #expect(request.body.isEmpty)
        }
    }

    @Test func endingIsADelete() async throws {
        try await Self.withFake { fake, client in
            try await client.endTurn("01jturnend")
            #expect(fake.requests.map(\.method) == ["DELETE"])
            #expect(fake.requests.map(\.path) == ["/turns/01jturnend"])
        }
    }

    @Test func gitCredentialsAreAskedForAndDecoded() async throws {
        try await Self.withFake { fake, client in
            let credential = try await client.gitCredentials(repository: "spatie/bloom", operation: .write, turnID: "01jturn")
            #expect(credential.token == "ghs_faketoken")
            #expect(credential.username == "x-access-token")
            let expected = try Date.ISO8601FormatStyle().parse("2026-09-17T10:00:00Z").addingTimeInterval(0.25)
            #expect(abs(credential.expiresAt.timeIntervalSince(expected)) < 0.001)
            #expect(!credential.description.contains("ghs_faketoken"))

            _ = try await client.gitCredentials(repository: "spatie/bloom", operation: .read, turnID: nil)
            let bodies = fake.requests("POST", "/git-credentials").compactMap(\.json)
            #expect(bodies.map { $0["repository"] as? String } == ["spatie/bloom", "spatie/bloom"])
            #expect(bodies.map { $0["operation"] as? String } == ["write", "read"])
            #expect(bodies.first?["turn_id"] as? String == "01jturn")
            #expect(bodies.last?["turn_id"] is NSNull)
        }
    }

    @Test func expiryReadsWithAndWithoutAFraction() throws {
        let whole = try #require(RunbloomGitCredentialBody.date("2026-09-17T10:00:00Z"))
        let micro = try #require(RunbloomGitCredentialBody.date("2026-09-17T10:00:00.500000Z"))
        #expect(micro.timeIntervalSince(whole) == 0.5)
        #expect(RunbloomGitCredentialBody.date("tomorrow") == nil)
    }

    @Test func aLimitRefusalCarriesTheLimitAndRetryAfter() async throws {
        try await Self.withFake { fake, client in
            fake.setStart(turnID: "t1", response: .limit("concurrent_machines", message: "Wait for another.", retryAfter: 60))
            await #expect(throws: RunbloomError.refused(status: 429, code: "limit_reached", message: "Wait for another.", limit: "concurrent_machines", retryAfter: 60)) {
                try await client.startTurn("t1")
            }
        }
    }

    @Test func refusalsAreMappedForEveryEndpoint() async throws {
        try await Self.withFake { fake, client in
            fake.script("POST", "/turns", .refusal(code: "missing_ability", message: "No prompting."))
            await #expect(throws: RunbloomError.refused(status: 403, code: "missing_ability", message: "No prompting.", limit: nil, retryAfter: nil)) {
                try await client.registerTurn(kind: .turn, chatID: "c", agent: .codex, sessionToken: "jwt")
            }
            fake.setStart(turnID: "t2", response: .refusal(status: 409, code: "turn_not_startable", message: "Too old."))
            await #expect(throws: RunbloomError.refused(status: 409, code: "turn_not_startable", message: "Too old.", limit: nil, retryAfter: nil)) {
                try await client.startTurn("t2")
            }
            fake.script("POST", "/git-credentials", .refusal(code: "write_outside_turn", message: "Read only."))
            await #expect(throws: RunbloomError.refused(status: 403, code: "write_outside_turn", message: "Read only.", limit: nil, retryAfter: nil)) {
                try await client.gitCredentials(repository: "a/b", operation: .write, turnID: nil)
            }
        }
    }

    @Test func aServerErrorIsUnreachableAndABodilessRefusalIsUnexpected() async throws {
        try await Self.withFake { fake, client in
            fake.script("POST", "/summary", FakeControlServer.Scripted(status: 503, body: "down"))
            await #expect(throws: RunbloomError.unreachable("runbloom.app answered 503.")) {
                try await client.postSummary(Data("{}".utf8))
            }
            fake.script("POST", "/usage", FakeControlServer.Scripted(status: 422, body: "<html>"))
            await #expect(throws: RunbloomError.unexpected(status: 422)) {
                try await client.postUsage(Data("{}".utf8))
            }
        }
    }

    @Test func aWrongSecretIsRefusedAndNeverRepeatedInTheError() async throws {
        let fake = try await FakeControlServer.start()
        let secret = "the-wrong-secret-value"
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: secret, http: .shared)
        do {
            try await client.postSummary(Data("{}".utf8))
            Issue.record("A wrong secret was accepted.")
        } catch {
            #expect(error as? RunbloomError == .refused(status: 401, code: "invalid_workspace_secret", message: "The workspace secret is not valid.", limit: nil, retryAfter: nil))
            #expect(fake.requests.count == 1, "The file held no other secret, so the call is not sent again")
            #expect(!String(describing: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }
        await fake.stop()
    }

    @Test func aRefusedSecretIsReadAgainAndTheCallSentOnceMoreWithTheRotatedOne() async throws {
        let fake = try await FakeControlServer.start()
        let file = Mutex("the-secret-before-rotation")
        let secret = WorkspaceSecret(file.withLock { $0 }) { file.withLock { $0 } }
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: secret, http: .shared)
        file.withLock { $0 = fake.secret }
        try await client.postSummary(Data("{}".utf8))
        #expect(fake.requests.map(\.authorization) == ["Bearer the-secret-before-rotation", "Bearer \(fake.secret)"])
        #expect(secret.current == fake.secret)
        await fake.stop()
    }

    @Test func aRotatedSecretIsTakenFromTheFileAndAnUnreadableFileKeepsTheOldOne() {
        let file = Mutex<String?>("second")
        let secret = WorkspaceSecret("first") {
            guard let value = file.withLock({ $0 }) else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        #expect(secret.reload())
        #expect(secret.current == "second")
        #expect(!secret.reload(), "The same secret again is no change")
        file.withLock { $0 = nil }
        #expect(!secret.reload())
        #expect(secret.current == "second")
    }

    @Test func anUnreachableHostNeverRepeatsTheSecret() async throws {
        let fake = try await FakeControlServer.start()
        let address = fake.baseURL
        await fake.stop()
        let secret = "secret-that-must-not-leak"
        let client = RunbloomClient(baseURL: address, workspaceID: "01jgone", secret: secret, http: .shared, timeout: .milliseconds(500))
        do {
            _ = try await client.environment()
            Issue.record("A stopped server answered.")
        } catch {
            guard case .unreachable = error as? RunbloomError else {
                Issue.record("Expected unreachable, got \(error)")
                return
            }
            #expect(!String(describing: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test func theKeySetIsServedWhenSet() async throws {
        try await Self.withFake { fake, _ in
            var request = HTTPClientRequest(url: fake.baseURL + "/.well-known/jwks.json")
            request.method = .GET
            let missing = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
            #expect(missing.status.code == 404)

            fake.jwks = Data(#"{"keys":[]}"#.utf8)
            let found = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
            #expect(found.status.code == 200)
            let body = try await found.body.collect(upTo: 1024)
            #expect(String(buffer: body) == #"{"keys":[]}"#)
        }
    }
}

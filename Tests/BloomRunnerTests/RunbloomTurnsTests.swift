import AsyncHTTPClient
import BloomCore
import BloomProtocol
import Foundation
import Testing
@testable import BloomRunner

struct RunbloomTurnsTests {
    private static func withTurns(_ body: (FakeControlServer, RunbloomTurns) async throws -> Void) async throws {
        let fake = try await FakeControlServer.start()
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared)
        let turns = RunbloomTurns(client: client, endAttempts: 4, endRetryDelay: .milliseconds(10))
        do {
            try await body(fake, turns)
        } catch {
            await fake.stop()
            throw error
        }
        await fake.stop()
    }

    private static func prompter(token: String?) -> RemoteCaller {
        RemoteCaller(author: nil, abilities: ["view", "prompt"], sessionToken: token)
    }

    @Test func registerSendsTheCallersToken() async throws {
        try await Self.withTurns { fake, turns in
            let chat = SessionID(rawValue: "chat-7")
            let turn = try await turns.register(.turn, chat: chat, agent: .codex, caller: Self.prompter(token: "fresh.jwt"))
            #expect(turn == FakeControlServer.turnID(1))
            let json = try #require(fake.requests("POST", "/turns").first?.json)
            #expect(json["session_token"] as? String == "fresh.jwt")
            #expect(json["chat_id"] as? String == "chat-7")
            #expect(json["agent"] as? String == "codex")
        }
    }

    @Test func aCallerWithNoTokenIsRefusedWithoutAsking() async throws {
        try await Self.withTurns { fake, turns in
            await #expect(throws: RemoteFailure.self) {
                try await turns.register(.terminal, chat: nil, agent: nil, caller: .server)
            }
            do {
                _ = try await turns.register(.terminal, chat: nil, agent: nil, caller: Self.prompter(token: ""))
            } catch let failure as RemoteFailure {
                #expect(failure.code == .unauthenticated)
            }
            #expect(fake.requests.isEmpty)
        }
    }

    @Test(arguments: [
        ("missing_ability", WireErrorCode.missingAbility),
        ("invalid_session_token", WireErrorCode.unauthenticated),
        ("github_not_connected", WireErrorCode.invalidValue),
    ])
    func registerRefusalsBecomeWireFailures(code: String, expected: WireErrorCode) async throws {
        try await Self.withTurns { fake, turns in
            fake.script("POST", "/turns", .refusal(code: code, message: "Said by runbloom.app."))
            do {
                _ = try await turns.register(.turn, chat: SessionID(rawValue: "c"), agent: .claudeCode, caller: Self.prompter(token: "jwt"))
                Issue.record("The refusal was not thrown.")
            } catch let failure as RemoteFailure {
                #expect(failure == RemoteFailure(expected, "Said by runbloom.app."))
            }
        }
    }

    @Test func startHandsBackTheGrant() async throws {
        try await Self.withTurns { fake, turns in
            fake.setStart(turnID: "t1", response: .grant(keys: ["claude": ("sk-ant", "id-1", "team")], environment: ["A": "1"]))
            let grant = try await turns.start(turnID: "t1")
            #expect(grant.agentKeys[.claudeCode]?.identity == "id-1")
            #expect(grant.environment(for: .claudeCode)["ANTHROPIC_API_KEY"] == "sk-ant")
            #expect(grant.environment["A"] == "1")
        }
    }

    @Test(arguments: [
        ("monthly_usage", 403),
        ("concurrent_machines", 429),
        ("total_machines", 403),
        ("kill_switch", 403),
    ])
    func aLimitBlocksTheTurn(limit: String, status: Int) async throws {
        try await Self.withTurns { fake, turns in
            fake.setStart(turnID: "t1", response: .limit(limit, message: "The team is out.", retryAfter: status == 429 ? 60 : nil))
            await #expect(throws: RemoteTurnRefusal.blocked(DeliveryBlock(limit: limit, message: "The team is out."))) {
                try await turns.start(turnID: "t1")
            }
        }
    }

    @Test(arguments: [
        ("no_agent_key", 403),
        ("not_a_collaborator", 403),
        ("no_push_access", 403),
        ("github_not_connected", 403),
        ("turn_not_startable", 409),
    ])
    func everyOtherRefusalIsRefused(code: String, status: Int) async throws {
        try await Self.withTurns { fake, turns in
            fake.setStart(turnID: "t1", response: .refusal(status: status, code: code, message: "Fix it."))
            await #expect(throws: RemoteTurnRefusal.refused(code: code, message: "Fix it.")) {
                try await turns.start(turnID: "t1")
            }
        }
    }

    @Test func anUnreachableStartThrowsSoTheQueuePauses() async throws {
        try await Self.withTurns { fake, turns in
            fake.script("POST", "/turns/t1/start", FakeControlServer.Scripted(status: 502, body: nil))
            await #expect(throws: RunbloomError.unreachable("runbloom.app answered 502.")) {
                try await turns.start(turnID: "t1")
            }
        }
    }

    @Test func endRetriesUntilRunbloomAnswers() async throws {
        try await Self.withTurns { fake, turns in
            let down = FakeControlServer.Scripted(status: 503, body: nil)
            fake.script("DELETE", "/turns/t1", down, down)
            await turns.end(turnID: "t1")
            #expect(fake.requests("DELETE", "/turns/t1").count == 3)
        }
    }

    @Test func endGivesUpAfterItsAttempts() async throws {
        try await Self.withTurns { fake, turns in
            let down = FakeControlServer.Scripted(status: 503, body: nil)
            fake.script("DELETE", "/turns/t1", down, down, down, down, down)
            await turns.end(turnID: "t1")
            #expect(fake.requests("DELETE", "/turns/t1").count == 4)
        }
    }

    @Test func endDoesNotRetryARefusal() async throws {
        try await Self.withTurns { fake, turns in
            fake.script("DELETE", "/turns/t1", .refusal(status: 404, code: "not_found", message: "No such turn."))
            await turns.end(turnID: "t1")
            #expect(fake.requests("DELETE", "/turns/t1").count == 1)
        }
    }
}

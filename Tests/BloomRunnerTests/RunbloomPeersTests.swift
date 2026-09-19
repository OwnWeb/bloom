import AsyncHTTPClient
import BloomCore
import BloomProtocol
import Foundation
import Testing
@testable import BloomRunner

/// Reaching another Bloom Cloud workspace: runbloom.app lists and mints, the other machine is
/// spoken to directly. The fake stands for both, since each is only an HTTP answer here.
@Suite("Messaging another Bloom Cloud workspace")
struct RunbloomPeersTests {
    private static func withFake(_ body: (FakeControlServer, WorkspacePeers) async throws -> Void) async throws {
        let fake = try await FakeControlServer.start()
        let client = RunbloomClient(baseURL: fake.baseURL + "/", workspaceID: fake.workspaceID, secret: fake.secret, http: .shared)
        do {
            try await body(fake, RunbloomPeers.peers(client: client, http: .shared))
        } catch {
            await fake.stop()
            throw error
        }
        await fake.stop()
    }

    static let listed = FakeControlServer.Scripted.json(200, ["workspaces": [
        ["id": "01k5self", "name": "Here", "state": "running", "is_self": true],
        ["id": "01k5other", "name": "Queue retries", "state": "running", "is_self": false],
    ]])

    static func minted(_ fake: FakeControlServer) -> FakeControlServer.Scripted {
        .json(201, ["token": "peer-token", "expires_at": "2026-09-19T12:05:00Z",
                    "workspace": ["id": "01k5other", "name": "Queue retries", "address": fake.baseURL]])
    }

    static func reply(_ result: OperationResult) throws -> FakeControlServer.Scripted {
        .raw(200, String(decoding: try WireJSON.encode(CommandReply(commandID: "c", result: result)), as: UTF8.self))
    }

    static let date = Date(timeIntervalSince1970: 1_789_638_002)
    static let controls = ComposerControlsRecord(agent: "claude", model: "opus[1m]", effort: "high", permissionMode: "acceptEdits",
                                                 interactionMode: "build")

    static func snapshot(chats: [ChatRecord]) -> OperationResult {
        .workspace(WorkspaceSnapshotRecord(
            workspace: WorkspaceRecord(id: "01k5other", name: "Queue retries", branch: "b", baseBranch: "main",
                                       setup: SetupRecord(state: "succeeded")),
            chats: chats, presence: [], cursor: 0, composerDefaults: controls))
    }

    static func chat(_ id: String, _ title: String, updated: TimeInterval, parent: String? = nil) -> ChatRecord {
        ChatRecord(id: id, title: title, agent: "claude", model: "opus[1m]", effort: "high", permissionMode: "acceptEdits",
                   interactionMode: "build", state: "idle", parentChatID: parent, lastSeq: 3, createdAt: date,
                   updatedAt: date.addingTimeInterval(updated))
    }

    @Test("the list leaves this workspace out")
    func listing() async throws {
        try await Self.withFake { fake, peers in
            fake.script("GET", "/workspaces", Self.listed)
            #expect(await peers.list("01jturn") == .listed([PeerWorkspace(id: "01k5other", name: "Queue retries", state: "running")]))
        }
    }

    /// Minted for the turn with `view` and `prompt` only, spoken to at the address runbloom.app gave,
    /// into the most recent chat that is not a crew member's, with the label on it.
    @Test("a message is minted for, sent with the minted token, and labelled")
    func sending() async throws {
        try await Self.withFake { fake, peers in
            fake.script("GET", "/workspaces", Self.listed)
            fake.script("POST", "/tokens", Self.minted(fake))
            fake.script("POST", "/_bloom/v1/rpc",
                        try Self.reply(Self.snapshot(chats: [
                            Self.chat("chat-old", "Older", updated: 0),
                            Self.chat("chat-new", "Newer", updated: 60),
                            Self.chat("chat-crew", "tests", updated: 120, parent: "chat-new"),
                        ])),
                        try Self.reply(.queued(promptID: "p1")))
            let answer = await peers.say(PeerMessage(turnID: "01jturn", workspace: "queue retries", chat: nil,
                                                     text: "Rebase on main", via: MessageVia(workspace: "Here", chat: "Chat")))
            #expect(answer == .sent(workspace: "Queue retries", chat: "Newer", queued: true))

            let mint = try #require(fake.requests("POST", "/tokens").first?.json)
            #expect(mint["turn_id"] as? String == "01jturn")
            #expect(mint["workspace_id"] as? String == "01k5other")
            #expect(mint["abilities"] as? [String] == ["view", "prompt"])

            let calls = fake.requests("POST", "/_bloom/v1/rpc")
            #expect(calls.allSatisfy { $0.authorization == "Bearer peer-token" }, "the minted token, never this machine's secret")
            let send = try #require(calls.last?.json?["operation"] as? [String: Any])
            #expect(send["chat_id"] as? String == "chat-new", "the newest top-level chat, never a crew member's")
            #expect((send["via"] as? [String: Any])?["workspace"] as? String == "Here")
        }
    }

    /// A Mac that is not connected: left with runbloom.app, once, whatever happens to the answer.
    @Test("a deposit for a closed Mac is sent once under one key, and a limit says how long to wait")
    func depositForAClosedMac() async throws {
        let fake = try await FakeControlServer.start()
        let client = RunbloomClient(baseURL: fake.baseURL + "/", workspaceID: fake.workspaceID, secret: fake.secret, http: .shared)
        let deposit = MacDeposit(turnID: "01jturn", workspace: "fix-login", text: "The migration is in.", chat: "Chat",
                                 idempotencyKey: "call-1")
        fake.script("POST", "/mac-messages", .raw(503, "{}"), .json(202, ["queued": true, "expires_at": "2026-09-26T13:00:00Z"]))
        let answer = await RunbloomPeers.depositForMac(deposit, client: client, pause: { _ in })
        #expect(answer == .queued(expiresAt: "2026-09-26T13:00:00Z"))
        let sent = fake.requests("POST", "/mac-messages")
        #expect(sent.count == 2)
        #expect(Set(sent.map(\.idempotencyKey)) == ["call-1"], "a retry is the same request, so it cannot queue twice")
        let body = try #require(try JSONSerialization.jsonObject(with: sent[0].body) as? [String: Any])
        #expect(body["turn_id"] as? String == "01jturn")
        #expect(body["target_workspace"] as? String == "fix-login")
        #expect((body["via"] as? [String: Any])?["chat"] as? String == "Chat")
        #expect(body["user_id"] == nil && body["recipient"] == nil, "runbloom.app decides who receives it")

        fake.script("POST", "/mac-messages", .json(429, ["code": "too_many_requests", "message": "This workspace has sent enough for now.",
                                                         "retry_after": 90]))
        #expect(await RunbloomPeers.depositForMac(deposit, client: client, pause: { _ in })
            == .refused("This workspace has sent enough for now. Try again in 2 minutes."))
        fake.script("POST", "/mac-messages", .refusal(status: 409, code: "mailbox_full", message: "Their Mac has 50 messages waiting."))
        #expect(await RunbloomPeers.depositForMac(deposit, client: client, pause: { _ in }) == .refused("Their Mac has 50 messages waiting."))
        await fake.stop()
    }

    @Test("a workspace the list does not have is refused before anything is minted, and refusals are passed on")
    func refusals() async throws {
        try await Self.withFake { fake, peers in
            fake.script("GET", "/workspaces", Self.listed)
            let unknown = await peers.say(PeerMessage(turnID: "t", workspace: "Nowhere", chat: nil, text: "Hi", via: MessageVia()))
            guard case .refused(let sentence) = unknown else { Issue.record("Sent to a workspace nobody listed"); return }
            #expect(sentence.contains("workspace_list"))
            #expect(fake.requests("POST", "/tokens").isEmpty)

            let off = "Letting a running agent message other Bloom Cloud workspaces is off for this team."
            fake.script("GET", "/workspaces", .refusal(code: "workspace_messaging_disabled", message: off))
            #expect(await peers.list("t") == .refused(off))
        }
    }
}

import Foundation
import Testing
@testable import BloomCore

/// The bridge tools reaching a Bloom Cloud workspace from this Mac. The machine is a fake here:
/// what is pinned is every decision the core makes about it, which is which workspace a name
/// means, which chat a message goes to, what is left out of a transcript, how pages are cut and
/// what is refused.
@Suite("Bloom Cloud workspaces through the Mac's bridge", .tags(.persistence), .scratchDirectory)
struct CloudWorkspaceReachTests {
    /// A machine with two chats, one of them a subagent's, and a transcript with a message between
    /// two people in the middle of it.
    private final class Machine: @unchecked Sendable {
        var sent: [(chat: String, text: String)] = []
        var transcriptAsks = 0
        var sendAnswer: Result<Bool, CloudReachTrouble> = .success(true)

        let target = CloudWorkspaceTarget(
            id: "01cloud", name: "Payments", state: "idle", repository: "spatie/payments", branch: "freek/payments"
        )

        func reach() -> CloudWorkspaceReach {
            CloudWorkspaceReach(
                workspaces: { [target] in [target] },
                chats: { _ in
                    .success([
                        CloudChatSummary(id: "c-old", title: "Old", agent: "claude", state: "idle", lastSeq: 3,
                                         updatedAt: Date(timeIntervalSince1970: 100)),
                        CloudChatSummary(id: "c-new", title: "Main", agent: "claude", state: "idle", lastSeq: 9,
                                         updatedAt: Date(timeIntervalSince1970: 200)),
                        CloudChatSummary(id: "c-sub", title: "Helper", agent: "claude", state: "running",
                                         parentChatID: "c-new", updatedAt: Date(timeIntervalSince1970: 300)),
                    ])
                },
                transcript: { [self] _, _, after, limit in
                    transcriptAsks += 1
                    let all = (0..<6).map { seq in
                        Message(
                            sessionID: SessionID("c-new"), seq: seq, kind: .user,
                            payload: Data(#"{"type":"user","message":{"content":[{"type":"text","text":"line \#(seq)"}]}}"#.utf8),
                            audience: seq == 2 ? MessageAudience(kind: .person, userID: "u-seb") : nil
                        )
                    }
                    let rest = all.filter { $0.seq > after }
                    return .success((Array(rest.prefix(limit)), rest.count > limit))
                },
                send: { [self] _, chat, text in
                    sent.append((chat, text))
                    return sendAnswer
                },
                changes: { _ in
                    .success(CloudWorkspaceChanges(branch: "freek/payments", baseBranch: "main", files: [
                        ChangedFile(path: "README.md", change: .modified, additions: 1, deletions: 0),
                    ]))
                },
                patch: { _, path in .success("diff --git a/\(path) b/\(path)\n+one line\n") }
            )
        }
    }

    private func fixture(_ label: String) async throws -> (Store, BridgeIdentity) {
        let store = try makeTestStore(label)
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Here", branch: "here", path: TestScratch.unique("here"), baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        return (store, BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .workspace))
    }

    private func request(_ method: String, _ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .integer(1), method: method, params: .object(arguments))
    }

    @Test("a name no local workspace has finds the Bloom Cloud one, and a local one wins a tie")
    func lookup() async throws {
        let (store, identity) = try await fixture("cloud-lookup")
        let reach = Machine().reach()

        let cloud = try await BridgeReadTarget.resolve(
            request("chat_list", ["workspace": .string("Payments")]), as: identity, store: store, cloud: reach
        )
        #expect(cloud == .success(.cloud(Machine().target)))

        let local = try await BridgeReadTarget.resolve(
            request("chat_list", ["workspace": .string("Here")]), as: identity, store: store, cloud: reach
        )
        guard case .success(.named(let workspace)) = local else {
            Issue.record("expected the local workspace")
            return
        }
        #expect(workspace.name == "Here")

        let unknown = try await BridgeReadTarget.resolve(
            request("chat_list", ["workspace": .string("Nope")]), as: identity, store: store, cloud: reach
        )
        #expect(unknown == .failure(.unknown(given: "Nope", known: ["Here", "Payments"])))
    }

    @Test("without a way into Bloom Cloud, nothing changes")
    func noReach() async throws {
        let (store, identity) = try await fixture("cloud-none")
        let result = await ChatListTool().call(request("chat_list", ["workspace": .string("Payments")]), as: identity, store: store)
        #expect(result.isError)
        #expect(result.text.contains("no active workspace called 'Payments'"))
    }

    @Test("chat_list lists the machine's chats in the local shape, marked as Cloud")
    func chats() async throws {
        let (store, identity) = try await fixture("cloud-chats")
        let result = await ChatListTool(cloud: Machine().reach()).call(
            request("chat_list", ["workspace": .string("01cloud")]), as: identity, store: store
        )
        let answer = try #require(JSONValue.parse(result.text))
        #expect(answer["cloud"]?.boolValue == true)
        #expect(answer["count"]?.intValue == 3)
        #expect(answer["chats"]?.arrayValue?.first?["current"]?.boolValue == false)
    }

    /// A message one colleague wrote to another is never handed to an agent, on the machine or
    /// from here, and leaving it out must not end a page early.
    @Test("chat_read leaves out messages between people and still fills its pages")
    func readsWithoutPeople() async throws {
        let (store, identity) = try await fixture("cloud-read")
        let machine = Machine()
        let tool = ChatReadTool(cloud: machine.reach())

        let first = try #require(JSONValue.parse(await tool.call(
            request("chat_read", ["workspace": .string("Payments"), "chat": .string("Main"), "limit": .integer(2)]),
            as: identity, store: store
        ).text))
        #expect(first["messages"]?.arrayValue?.compactMap { $0["seq"]?.intValue } == [0, 1])
        let cursor = try #require(first["next_cursor"]?.stringValue)

        let second = try #require(JSONValue.parse(await tool.call(
            request("chat_read", ["workspace": .string("Payments"), "chat": .string("c-new"),
                                  "limit": .integer(2), "cursor": .string(cursor)]),
            as: identity, store: store
        ).text))
        #expect(second["messages"]?.arrayValue?.compactMap { $0["seq"]?.intValue } == [3, 4],
                "the message to a person, seq 2, is left out and the page is still two long")
        #expect(second["note"]?.stringValue?.contains("Bloom Cloud workspace 'Payments'") == true)
    }

    @Test("workspace_diff reads the machine's changes and pages them as a local diff")
    func diff() async throws {
        let (store, identity) = try await fixture("cloud-diff")
        let result = await WorkspaceDiffTool(cloud: Machine().reach()).call(
            request("workspace_diff", ["workspace": .string("Payments")]), as: identity, store: store
        )
        let answer = try #require(JSONValue.parse(result.text), "\(result.text)")
        #expect(answer["cloud"]?.boolValue == true)
        #expect(answer["branch"]?.stringValue == "freek/payments")
        #expect(answer["file_count"]?.intValue == 1)
        #expect(answer["diff"]?.stringValue?.contains("+one line") == true)
        #expect(answer["complete"]?.boolValue == true)

        let missing = await WorkspaceDiffTool(cloud: Machine().reach()).call(
            request("workspace_diff", ["workspace": .string("Payments"), "path": .string("nope.txt")]),
            as: identity, store: store
        )
        #expect(missing.isError)
    }

    @Test("workspace_say sends to the most recent top-level chat, never to a subagent's")
    func says() async throws {
        let (store, identity) = try await fixture("cloud-say")
        let machine = Machine()
        let tool = WorkspaceSayTool({ _ in .refused("not local") }, cloud: machine.reach())

        let result = await tool.call(
            request("workspace_say", ["workspace": .string("Payments"), "message": .string("Please rebase.")]),
            as: identity, store: store
        )
        let answer = try #require(JSONValue.parse(result.text), "\(result.text)")
        #expect(machine.sent.map(\.chat) == ["c-new"])
        #expect(machine.sent.map(\.text) == ["Please rebase."], "the words go as written, with nothing added")
        #expect(answer["state"]?.stringValue == "sent")
        #expect(answer["cloud"]?.boolValue == true)
        #expect(answer["notify_when_done"]?.boolValue == false)
    }

    @Test("the same brake as a local message: the same words twice are refused, but not from the owner")
    func throttled() async throws {
        let (store, identity) = try await fixture("cloud-throttle")
        let machine = Machine()
        let tool = WorkspaceSayTool({ _ in .refused("not local") }, cloud: machine.reach())
        let words = request("workspace_say", ["workspace": .string("Payments"), "message": .string("Same again.")])

        _ = await tool.call(words, as: identity, store: store)
        let again = await tool.call(words, as: identity, store: store)
        #expect(again.isError)
        #expect(machine.sent.count == 1)

        let fromOwner = await tool.call(words, as: .owner, store: store)
        #expect(!fromOwner.isError)
        #expect(machine.sent.count == 2)
    }

    @Test("the machine's refusal is passed on as its sentence")
    func refused() async throws {
        let (store, identity) = try await fixture("cloud-refused")
        let machine = Machine()
        machine.sendAnswer = .failure(CloudReachTrouble("Your access to this workspace does not include prompting."))
        let result = await WorkspaceSayTool({ _ in .refused("not local") }, cloud: machine.reach()).call(
            request("workspace_say", ["workspace": .string("Payments"), "message": .string("Go.")]),
            as: identity, store: store
        )
        #expect(result.isError)
        #expect(result.text.contains("does not include prompting"))
    }

    @Test("workspace_list lists Bloom Cloud workspaces after this Mac's, and none under a project")
    func listed() async throws {
        let (store, _) = try await fixture("cloud-list")
        let tool = WorkspaceListTool(cloud: Machine().reach())
        let all = try #require(JSONValue.parse(await tool.call(request("workspace_list", [:]), as: .owner, store: store).text))
        let rows = try #require(all["workspaces"]?.arrayValue)
        #expect(rows.last?["cloud"]?.boolValue == true)
        #expect(rows.last?["id"]?.stringValue == "01cloud")

        let narrowed = try #require(JSONValue.parse(await tool.call(
            request("workspace_list", ["project": .string("bloom")]), as: .owner, store: store
        ).text))
        #expect(narrowed["workspaces"]?.arrayValue?.contains { $0["cloud"]?.boolValue == true } == false)
    }
}

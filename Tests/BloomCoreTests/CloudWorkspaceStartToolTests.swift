import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("cloud_workspace_start", .scratchDirectory)
struct CloudWorkspaceStartToolTests {
    private let identity = BridgeIdentity(sessionID: SessionID("chat-1"), workspaceID: WorkspaceID("ws-1"), role: .workspace)

    private func call(_ tool: CloudWorkspaceStartTool, _ arguments: [String: JSONValue]) async throws -> BridgeToolResult {
        let store = try makeTestStore("cloud-workspace-start")
        return await tool.call(MCPRequest(id: .integer(1), method: CloudWorkspaceStartTool.name, params: .object(arguments)),
                               as: identity, store: store)
    }

    @Test("the order carries what the agent asked for, and the answer carries the address to open")
    func createdAnswerCarriesTheURL() async throws {
        let asked = Mutex<CloudWorkspaceOrder?>(nil)
        let tool = CloudWorkspaceStartTool { order, _, _ in
            asked.withLock { $0 = order }
            return .created(CloudWorkspaceCreated(id: "01k5new", name: order.name, state: "setting_up", url: "https://runbloom.app/w/01k5new"))
        }
        let answer = try await call(tool, ["name": .string(" Try the retry "), "base_branch": .string("main"), "run_setup": .bool(false)])

        #expect(!answer.isError)
        #expect(asked.withLock { $0 } == CloudWorkspaceOrder(name: "Try the retry", baseBranch: "main", runSetup: false))
        #expect(answer.text.contains("https://runbloom.app/w/01k5new"),
                "nothing on a machine can look the workspace up afterwards, so the answer is all there is")
        #expect(answer.text.contains("no agent is working in it"))
    }

    /// The sentence names the team switch, and it is runbloom.app's: the agent passes it on.
    @Test("a refusal reaches the agent as it was written, and as an error")
    func refusalsPassThrough() async throws {
        let off = "Creating Bloom Cloud workspaces from an agent is off for this team. An admin can turn it on in Team settings."
        let answer = try await call(CloudWorkspaceStartTool { _, _, _ in .refused(off) }, ["name": .string("Spike")])
        #expect(answer.isError)
        #expect(answer.text == off)
    }

    @Test("a name is required, and run_setup has to be true or false")
    func argumentsAreChecked() async throws {
        let never = CloudWorkspaceStartTool { _, _, _ in
            Issue.record("asked runbloom.app with arguments it should have refused")
            return .refused("")
        }
        #expect(try await call(never, [:]).isError)
        #expect(try await call(never, ["name": .string("   ")]).isError)
        #expect(try await call(never, ["name": .string("Spike"), "run_setup": .string("yes")]).isError)
    }

    /// **The turn and the name**, so the agent asking again after a timeout gets the workspace the
    /// first call made rather than a second machine.
    @Test("asking twice for the same name in the same turn carries the same key, and nothing else does")
    func idempotencyKey() {
        let key = CloudWorkspaceRequest.idempotencyKey(turnID: "turn-1", name: "Spike")
        #expect(key == CloudWorkspaceRequest.idempotencyKey(turnID: "turn-1", name: " spike "))
        #expect(key != CloudWorkspaceRequest.idempotencyKey(turnID: "turn-2", name: "Spike"))
        #expect(key != CloudWorkspaceRequest.idempotencyKey(turnID: "turn-1", name: "Spike 2"))
    }
}

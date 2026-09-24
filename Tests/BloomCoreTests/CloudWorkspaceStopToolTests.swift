import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("cloud_workspace_stop", .scratchDirectory)
struct CloudWorkspaceStopToolTests {
    @Test("a workspace name is optional and a refusal reaches the agent")
    func acceptsSelfAndOther() async throws {
        let store = try makeTestStore("cloud-workspace-stop")
        let identity = BridgeIdentity(sessionID: SessionID("chat-1"), workspaceID: WorkspaceID("ws-1"), role: .workspace)
        let asked = Mutex<[String?]>([])
        let tool = CloudWorkspaceStopTool { workspace, _ in
            asked.withLock { $0.append(workspace) }
            return workspace == nil
                ? .requested(CloudWorkspaceStopped(id: CloudWorkspaceID("self"), name: "Here", state: "archiving"))
                : .refused("The workspace has unpushed work.")
        }
        let selfAnswer = await tool.call(MCPRequest(id: .integer(1), method: CloudWorkspaceStopTool.name,
                                                    params: .object([:])), as: identity, store: store)
        let otherAnswer = await tool.call(MCPRequest(id: .integer(2), method: CloudWorkspaceStopTool.name,
                                                     params: .object(["workspace": .string(" Other ")])),
                                          as: identity, store: store)
        #expect(!selfAnswer.isError)
        #expect(selfAnswer.text.contains("archiving"))
        #expect(otherAnswer.isError)
        #expect(otherAnswer.text == "The workspace has unpushed work.")
        #expect(asked.withLock { $0 } == [nil, "Other"])

        let empty = await tool.call(MCPRequest(id: .integer(3), method: CloudWorkspaceStopTool.name,
                                              params: .object(["workspace": .string(" ")])), as: identity, store: store)
        #expect(empty.isError)
        let malformed = await tool.call(MCPRequest(id: .integer(4), method: CloudWorkspaceStopTool.name,
                                                  params: .string("Other")), as: identity, store: store)
        #expect(malformed.isError)
        #expect(asked.withLock { $0 } == [nil, "Other"], "a malformed target must never fall back to self")
    }
}

import Foundation
import Testing
@testable import BloomCore

struct WorkspaceRestoreToolTests {
    @Test("restore is offered only to the owner and is self-approved")
    func permissions() async throws {
        let (store, workspace) = try await fixture()
        let tool = WorkspaceRestoreTool { _ in .restored(path: "/tmp/restored", relocatedFrom: nil) }
        let toolbox = BridgeToolbox(handlers: [tool])
        #expect(toolbox.handler(named: "workspace_restore", for: .owner) != nil)
        #expect(toolbox.handler(named: "workspace_restore", for: .workspace) == nil)
        #expect(BridgeToolApproval.isSelfApproved(
            toolName: "mcp__bloom-workspace-bridge__workspace_restore"
        ))

        let identity = BridgeIdentity(
            sessionID: SessionID("s"), workspaceID: workspace.id, role: .workspace
        )
        let result = await tool.call(request(["id": .string(workspace.id.rawValue)]), as: identity, store: store)
        #expect(result.isError)
    }

    @Test("the owner must pass only an archived workspace's exact id")
    func arguments() async throws {
        let (store, workspace) = try await fixture()
        let calls = RestoreCalls()
        let tool = WorkspaceRestoreTool { target in
            await calls.record(target)
            return .restored(path: target.path, relocatedFrom: nil)
        }
        for arguments: [String: JSONValue] in [
            [:], ["id": .integer(1)], ["id": .string(" ")],
            ["id": .string(workspace.name)], ["id": .string("missing")],
            ["id": .string(workspace.id.rawValue), "force": .bool(true)],
        ] {
            let result = await tool.call(request(arguments), as: .owner, store: store)
            #expect(result.isError)
        }
        #expect(await calls.workspaces.isEmpty)
    }

    @Test("an archived workspace is passed to the app and the restored path is reported")
    func restores() async throws {
        let (store, workspace) = try await fixture()
        let calls = RestoreCalls()
        let tool = WorkspaceRestoreTool { target in
            await calls.record(target)
            return .restored(path: "/tmp/other-path", relocatedFrom: target.path)
        }

        let result = await tool.call(
            request(["id": .string(workspace.id.rawValue)]), as: .owner, store: store
        )

        #expect(!result.isError)
        #expect(result.text.contains("/tmp/other-path"))
        #expect(result.text.contains(workspace.path))
        #expect(await calls.workspaces.map(\.id) == [workspace.id])
    }

    @Test("active workspaces and app refusals do not report a restore")
    func refusals() async throws {
        let (store, workspace) = try await fixture()
        let calls = RestoreCalls()
        let tool = WorkspaceRestoreTool { target in
            await calls.record(target)
            return .refused("The branch is gone.")
        }
        try await store.update(workspaceID: workspace.id) { $0.restore(to: workspace.path, hasSetupScript: false) }

        let active = await tool.call(
            request(["id": .string(workspace.id.rawValue)]), as: .owner, store: store
        )
        #expect(active.isError)
        #expect(await calls.workspaces.isEmpty)

        try await store.update(workspaceID: workspace.id) { $0.archive() }
        let refused = await tool.call(
            request(["id": .string(workspace.id.rawValue)]), as: .owner, store: store
        )
        #expect(refused.isError)
        #expect(refused.text.contains("The branch is gone"))
    }

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .integer(1), method: "workspace_restore", params: .object(arguments))
    }

    private func fixture() async throws -> (Store, Workspace) {
        let store = try makeTestStore("restore-tool")
        let repo = try await store.upsert(Repo(name: "Restore tool", path: "/tmp/restore-tool"))
        var workspace = Workspace(
            repoID: repo.id, name: "Older post", branch: "older-post",
            path: "/tmp/restore-tool-post", baseBranch: "main"
        )
        workspace.archive()
        workspace = try await store.upsert(workspace)
        return (store, workspace)
    }
}

private actor RestoreCalls {
    var workspaces: [Workspace] = []
    func record(_ workspace: Workspace) { workspaces.append(workspace) }
}

import Foundation

/// The app-side result of rebuilding an archived workspace's worktree.
public enum WorkspaceRestoreToolOutcome: Sendable, Equatable {
    case restored(path: String, relocatedFrom: String?)
    case refused(String)
}

public typealias WorkspaceRestoring = @Sendable (Workspace) async -> WorkspaceRestoreToolOutcome

/// Restores an archived workspace through the same lifecycle as Bloom's Restore button.
public struct WorkspaceRestoreTool: BridgeToolHandling {
    private let restore: WorkspaceRestoring

    public init(_ restore: @escaping WorkspaceRestoring) {
        self.restore = restore
    }

    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "workspace_restore",
        description: """
            Restore an archived workspace by rebuilding its worktree from its surviving local or \
            remote branch. Its chats and notes stay with it, and it returns to the active list. \
            Pass the exact archived workspace id from workspace_list with include_archived: true. \
            Only call when the owner has asked to restore that workspace. If its old path is \
            occupied, Bloom uses a free path and reports both paths. If the branch is gone, the \
            call is refused and the archived record remains readable. Restoring does not run the \
            project's setup script or recreate uncommitted files that were lost at archive time.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("The exact id of an archived workspace from workspace_list."),
                ]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(
        _ request: MCPRequest, as identity: BridgeIdentity, store: Store
    ) async -> BridgeToolResult {
        guard identity.role == .owner else {
            return .failure("Only the owner's own client can restore an archived workspace.")
        }
        guard case .object(let arguments)? = request.params,
              Set(arguments.keys) == ["id"],
              let rawID = request.stringParam("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty else {
            return .failure("Pass only 'id', using an archived workspace's exact id from workspace_list.")
        }

        let workspace: Workspace
        do {
            guard let found = try await store.workspace(id: WorkspaceID(rawID)) else {
                return .failure("No workspace has that id. Call workspace_list with include_archived: true.")
            }
            workspace = found
        } catch {
            return .failure("Bloom could not read that workspace. Nothing was restored; try again shortly.")
        }
        guard workspace.state == .archived else {
            return .failure("'\(workspace.name)' is active already. Nothing was restored.")
        }

        switch await restore(workspace) {
        case let .restored(path, relocatedFrom):
            if let relocatedFrom {
                return BridgeToolResult(text: "Restored '\(workspace.name)' at '\(path)'. Its old path '\(relocatedFrom)' was occupied.")
            }
            return BridgeToolResult(text: "Restored '\(workspace.name)' at '\(path)'.")
        case .refused(let reason):
            return .failure("Could not restore '\(workspace.name)'. \(reason)")
        }
    }
}

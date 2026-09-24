import Foundation

public struct CloudWorkspaceStopRequest: Sendable, Hashable {
    public let turnID: String
    /// Nil means the workspace this agent is running in. Otherwise an id or exact name.
    public let workspace: String?

    public init(turnID: String, workspace: String?) {
        self.turnID = turnID
        self.workspace = workspace
    }
}

public struct CloudWorkspaceStopped: Sendable, Hashable {
    public let id: CloudWorkspaceID
    public let name: String
    public let state: String

    public init(id: CloudWorkspaceID, name: String, state: String) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public enum CloudWorkspaceStopAnswer: Sendable, Hashable {
    case requested(CloudWorkspaceStopped)
    case refused(String)
}

/// Archiving a Cloud workspace deletes its machine and conversation. The server checks the
/// prompter's archive rights and its last git report before it accepts the request.
public struct CloudWorkspaceStopTool: BridgeToolHandling {
    public typealias Stopping = @Sendable (_ workspace: String?, _ sessionID: SessionID?) async -> CloudWorkspaceStopAnswer

    private let stop: Stopping

    public init(_ stop: @escaping Stopping) { self.stop = stop }

    public static let name = "cloud_workspace_stop"
    public let roles: Set<BridgeRole> = [.workspace]

    public let tool = BridgeTool(
        name: CloudWorkspaceStopTool.name,
        description: """
            Archive a Bloom Cloud workspace and stop its machine. This permanently deletes its
            conversation, worktree and any work not pushed to GitHub. Leave 'workspace' out to
            archive this workspace; your current turn may end as soon as the request is accepted.
            Pass an id or name from workspace_list to archive another workspace in this team.

            Only do this when the person you are working for has asked to stop that workspace, or
            when the workspace has finished its assigned task and they asked you to clean it up.
            runbloom.app checks that person may archive it. It refuses when it cannot confirm a
            recent, clean git report. Explain a refusal and let the person inspect it in Bloom.
            Call this only after all work and messages are complete.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string("An id or exact name from workspace_list. Leave it out for this workspace."),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard identity.workspaceID != nil else {
            return .failure("Only an agent working in a Bloom Cloud workspace can stop one from here.")
        }
        var arguments: [String: JSONValue] = [:]
        if let params = request.params {
            guard case .object(let object) = params else {
                return .failure("Pass an object with 'workspace', or no arguments to stop this workspace.")
            }
            arguments = object
        }
        guard Set(arguments.keys).isSubset(of: ["workspace"]) else {
            return .failure("Pass only 'workspace', or nothing to stop this workspace.")
        }
        if arguments["workspace"] != nil, CloudWorkspaceStartTool.text(request, "workspace") == nil {
            return .failure("Give another workspace's id or name, or leave 'workspace' out to stop this one.")
        }
        let workspace = CloudWorkspaceStartTool.text(request, "workspace")
        switch await stop(workspace, identity.sessionID) {
        case .refused(let sentence):
            return .failure(sentence)
        case .requested(let stopped):
            return .json(.object([
                "id": .string(stopped.id.rawValue),
                "name": .string(stopped.name),
                "state": .string(stopped.state),
                "note": .string("Archive accepted. The machine and conversation are being deleted."),
            ]))
        }
    }
}

import Foundation

/// `mac_workspace_say` on a Bloom Cloud machine: a message for a workspace on the Mac of the
/// person you are working for, sent down the connection their Mac has open to this workspace.
/// See `WorkspaceRuntime.sayToMac`.
public struct MacWorkspaceSayTool: BridgeToolHandling {
    public typealias Saying = @Sendable (_ workspace: String, _ text: String, _ sessionID: SessionID?) async -> MacSayAnswer

    private let say: Saying

    public init(_ say: @escaping Saying) { self.say = say }

    public static let name = "mac_workspace_say"
    public let roles: Set<BridgeRole> = [.workspace]

    public let tool = BridgeTool(
        name: MacWorkspaceSayTool.name,
        description: """
            Send a message to the agent in a workspace on the Mac of the person you are working \\
            for: a local Bloom workspace there, not a Bloom Cloud one. It goes straight to their \\
            Mac while they have this workspace open in Bloom on it; otherwise it is queued and \\
            arrives when Bloom on their Mac next checks in, and the answer says which.

            'workspace' is that local workspace's name as the person gave it to you; this machine \\
            cannot list a Mac's workspaces, and their Mac refuses a name it does not have. It \\
            arrives there marked as sent by an agent in this workspace, never as their own words.

            No reply comes back here. Your team has to have switched on messaging other workspaces.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string("The local workspace on their Mac, by the name they gave you."),
                ]),
                "message": .object([
                    "type": .string("string"),
                    "description": .string("What to say, written for an agent that cannot see this conversation."),
                ]),
            ]),
            "required": .array([.string("workspace"), .string("message")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard let workspace = CloudWorkspaceStartTool.text(request, "workspace") else {
            return .failure("Name the workspace on their Mac.")
        }
        guard let message = CloudWorkspaceStartTool.text(request, "message") else {
            return .failure("Write the message to send.")
        }
        switch await say(workspace, message, identity.sessionID) {
        case .refused(let sentence):
            return .failure(sentence)
        case .queued:
            return .init(text: "Queued for their Mac. It arrives when Bloom there next checks in. Whether \(workspace) "
                + "exists there is the Mac's to check, and no reply comes back here. Say what you sent and carry on.")
        case .sent(let connections):
            let reach = connections == 1 ? "their Mac" : "their Mac, on \(connections) connections"
            return .init(text: "Sent to \(reach). Whether \(workspace) exists there is the Mac's to check, "
                + "and no reply comes back here. Say what you sent and carry on with your own work.")
        }
    }
}

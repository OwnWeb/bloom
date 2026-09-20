import Foundation

/// `workspace_list` on a Bloom Cloud machine: the team's other Bloom Cloud workspaces this chat's
/// person could message. The Mac's tool of the same name lists local workspaces too; a machine has
/// none, so this is the half a machine can answer, through runbloom.app. See `WorkspacePeers`.
public struct PeerWorkspaceListTool: BridgeToolHandling {
    public typealias Listing = @Sendable (_ sessionID: SessionID?) async -> PeerListAnswer

    private let list: Listing

    public init(_ list: @escaping Listing) { self.list = list }

    public static let name = "workspace_list"
    public let roles: Set<BridgeRole> = [.workspace]

    public let tool = BridgeTool(
        name: PeerWorkspaceListTool.name,
        description: """
            List the team's other Bloom Cloud workspaces that the person you are working for can \\
            open: each one's id, name and state. Use an id or a name from here with workspace_say.

            Only workspaces in this team, and only the ones that person may open. Your team has to \\
            have switched this on; if it is off, the answer says which setting and where it is.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        switch await list(identity.sessionID) {
        case .refused(let sentence):
            return .failure(sentence)
        case .listed(let workspaces):
            return .json(.object([
                "workspaces": .array(workspaces.map {
                    .object(["id": .string($0.id), "name": .string($0.name), "state": .string($0.state)])
                }),
                "count": .integer(workspaces.count),
            ]))
        }
    }
}

/// `workspace_say` on a Bloom Cloud machine: a message to an agent in another of the team's Bloom
/// Cloud workspaces, sent as the person whose turn is running and labelled as an agent's there.
public struct PeerWorkspaceSayTool: BridgeToolHandling {
    public typealias Saying = @Sendable (
        _ workspace: String, _ chat: String?, _ text: String, _ sessionID: SessionID?
    ) async -> PeerSayAnswer

    private let say: Saying

    public init(_ say: @escaping Saying) { self.say = say }

    public static let name = "workspace_say"
    public let roles: Set<BridgeRole> = [.workspace]

    public let tool = BridgeTool(
        name: PeerWorkspaceSayTool.name,
        description: """
            Send a message to the agent in another of this team's Bloom Cloud workspaces. It is \\
            sent as the person you are working for, and it is marked there as written by an \\
            agent in this workspace, so nobody reads it as their own words.

            'workspace' is an id or a name from workspace_list. 'chat' is a chat there by id or \\
            exact title; leave it out for its most recent chat. If that agent is busy, the message \\
            waits in its queue.

            No reply comes back here. It starts a turn there, on that person's key and limits, so \\
            send one when the work genuinely belongs in that workspace, and say what you sent. \\
            Your team has to have switched this on.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string("The workspace, by an id or a name workspace_list reports."),
                ]),
                "message": .object([
                    "type": .string("string"),
                    "description": .string("What to say, written for an agent that cannot see this conversation."),
                ]),
                "chat": .object([
                    "type": .string("string"),
                    "description": .string("A chat there by id or exact title. Leave it out for its most recent chat."),
                ]),
            ]),
            "required": .array([.string("workspace"), .string("message")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard let workspace = CloudWorkspaceStartTool.text(request, "workspace") else {
            return .failure("Name the workspace, by an id or a name from workspace_list.")
        }
        guard let message = CloudWorkspaceStartTool.text(request, "message") else {
            return .failure("Write the message to send.")
        }
        switch await say(workspace, CloudWorkspaceStartTool.text(request, "chat"), message, identity.sessionID) {
        case .refused(let sentence):
            return .failure(sentence)
        case .sent(let name, let chat, let queued):
            return .json(.object([
                "state": .string(queued ? "queued" : "sent"),
                "workspace": .string(name),
                "chat": .string(chat),
                "note": .string("No reply comes back here. Say what you sent and carry on with your own work."),
            ]))
        }
    }
}

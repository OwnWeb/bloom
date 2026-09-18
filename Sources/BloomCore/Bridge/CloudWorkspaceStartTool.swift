import Foundation

/// What an agent asks for when it wants a Cloud workspace of its own made, before the machine
/// adds the turn it is asking in.
public struct CloudWorkspaceOrder: Sendable, Hashable {
    public var name: String
    public var branch: String?
    public var baseBranch: String?
    public var runSetup: Bool
    public var project: String?

    public init(name: String, branch: String? = nil, baseBranch: String? = nil, runSetup: Bool = true, project: String? = nil) {
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.runSetup = runSetup
        self.project = project
    }
}

/// The workspace runbloom.app made. **All the agent will ever know about it**: nothing on a
/// machine can list or read another workspace, so the answer carries the address a person opens.
public struct CloudWorkspaceCreated: Sendable, Hashable {
    public var id: String
    public var name: String
    public var state: String
    public var url: String

    public init(id: String, name: String, state: String, url: String) {
        self.id = id
        self.name = name
        self.state = state
        self.url = url
    }
}

public enum CloudWorkspaceAnswer: Sendable, Hashable {
    case created(CloudWorkspaceCreated)
    /// A sentence for the agent to pass on, as runbloom.app or the machine wrote it.
    case refused(String)
}

/// `cloud_workspace_start`: an agent on a Cloud machine asking runbloom.app for another Cloud
/// workspace. The Mac has a tool of the same name taking the same arguments, so an agent sees one
/// thing wherever it runs.
///
/// **The machine asks; it never creates.** A machine has no business making machines, and
/// everything that decides whether one is made is runbloom.app's: the team switch, which is off by
/// default, the limits, whether the person may create in the project at all, and the rule that a
/// workspace an agent made cannot make another. The machine contributes one fact, the turn it is
/// running in, which is how runbloom.app knows who is asking and who pays. It never names a person.
///
/// **Always listed, even when the team has it switched off.** The machine cannot know the switch
/// without asking, and an agent told "no such tool" cannot help anybody find the setting;
/// runbloom.app's refusal names it, and that sentence is what the agent gets.
///
/// **No `prompt` yet.** Delivering one means runbloom.app holding the words until the new machine
/// boots, which its design says it never does. Freek approved it as a written exception on 18
/// September 2026, a one-time handoff fetched by the new machine and deleted once it is stored, and
/// until that handoff exists the workspace is made empty, the description says so, and the
/// argument is not offered: a parameter that can only be refused is advice to a dead end.
public struct CloudWorkspaceStartTool: BridgeToolHandling {
    public typealias Starting = @Sendable (
        _ order: CloudWorkspaceOrder, _ sessionID: SessionID?, _ workspaceID: WorkspaceID
    ) async -> CloudWorkspaceAnswer

    private let start: Starting

    public init(_ start: @escaping Starting) {
        self.start = start
    }

    public static let name = "cloud_workspace_start"

    public let roles: Set<BridgeRole> = [.workspace]

    public let tool = BridgeTool(
        name: CloudWorkspaceStartTool.name,
        description: """
            Create another Bloom Cloud workspace in this project: a machine of its own, with its \
            own branch, for a person to open. It is created as the person whose message you are \
            answering, and it costs them real money for as long as it runs.

            Nothing runs in it yet. It starts empty, with no agent working and no task, so do not \
            tell anybody you handed work to it. Say what it is for, give them the url, and let them \
            open it and write the first message themselves.

            Only when the work genuinely needs its own branch and its own pull request. For help \
            on this branch, use agent_start instead, which costs nothing extra.

            Your team has to have switched this on, and it is off by default. If it is off, the \
            answer says which setting and where it is: tell the person that sentence rather than \
            trying again. A workspace created this way cannot create others.

            It returns as soon as the workspace exists, which is before its setup has run; setup \
            takes minutes. There is no way to look it up afterwards from here, so pass on what \
            the answer says.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("What to call it. Short, and saying what it is for."),
                ]),
                "branch": .object([
                    "type": .string("string"),
                    "description": .string("The new branch's name. Leave it out and it is made from the name."),
                ]),
                "base_branch": .object([
                    "type": .string("string"),
                    "description": .string("The branch to cut it from. Leave it out for the project's default branch."),
                ]),
                "run_setup": .object([
                    "type": .string("boolean"),
                    "description": .string("Whether its setup scripts run. Defaults to true."),
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string("Leave it out: from here only this project is supported."),
                ]),
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure("Only an agent working in a Bloom Cloud workspace can create another one from here.")
        }
        guard let name = Self.text(request, "name") else {
            return .failure("Give the new workspace a name.")
        }
        var order = CloudWorkspaceOrder(name: name, branch: Self.text(request, "branch"),
                                        baseBranch: Self.text(request, "base_branch"), project: Self.text(request, "project"))
        if let stated = request.param("run_setup"), stated != .null {
            guard let flag = stated.boolValue else { return .failure("run_setup is true or false.") }
            order.runSetup = flag
        }
        switch await start(order, identity.sessionID, workspaceID) {
        case .refused(let sentence):
            return .failure(sentence)
        case .created(let workspace):
            return .json(.object([
                "id": .string(workspace.id),
                "name": .string(workspace.name),
                "state": .string(workspace.state),
                "url": .string(workspace.url),
                "note": .string("Created empty: no agent is working in it. Give the person the url to open it."),
            ]))
        }
    }

    /// A trimmed string argument, or nil when it is absent, null or empty.
    static func text(_ request: MCPRequest, _ key: String) -> String? {
        guard let value = request.stringParam(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

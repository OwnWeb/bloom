import Foundation

/// What an agent asks for when it wants a Cloud workspace of its own made, before the machine
/// adds the turn it is asking in.
public struct CloudWorkspaceOrder: Sendable, Hashable {
    public var name: String
    public var branch: String?
    public var baseBranch: String?
    public var runSetup: Bool
    public var project: String?
    /// The new workspace's first message, sent as the same person once its setup has run. Nil makes
    /// an empty workspace for them to open.
    public var prompt: String?
    /// The reasoning effort for the opening chat, or nil to inherit the creating chat or machine default.
    public var effort: String?

    public init(name: String, branch: String? = nil, baseBranch: String? = nil, runSetup: Bool = true, project: String? = nil,
                prompt: String? = nil, effort: String? = nil) {
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.runSetup = runSetup
        self.project = project
        self.prompt = prompt
        self.effort = effort
    }

    /// runbloom.app refuses more, and the machine's own front refuses a body over 1 MiB before
    /// runbloom.app ever sees it.
    public static let promptLimit = 512 * 1_024
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
/// **`prompt` is handed over once.** Delivering one means runbloom.app holding the words until the
/// new machine boots, which its design says it never does; Freek approved it as a written exception
/// on 18 September 2026. The new machine fetches it with its own secret, keeps it, tells
/// runbloom.app it has it, and runs it as the person who asked, on the creating chat's agent and
/// model, after its setup. See `RemoteOpening`.
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
            own branch. It is created as the person whose message you are answering, and it costs \
            them real money for as long as it runs.

            Pass 'prompt' to give it a task: an agent starts on it once the new workspace has set \
            itself up, which takes minutes, as the same person, on the agent and model you are \
            running on. Pass 'effort' to choose that opening chat's reasoning effort, or leave it \
            out to inherit your current effort. It cannot see this conversation, so write the prompt as if to someone who \
            has just opened the project. Leave 'prompt' out for an empty workspace a person opens \
            and writes the first message in themselves.

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
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("The new workspace's first task. Leave it out for an empty workspace."),
                ]),
                "effort": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The opening chat's exact reasoning effort id, such as low, medium or "
                            + "high. Leave it out to inherit the creating chat's effort."
                    ),
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
                                        baseBranch: Self.text(request, "base_branch"), project: Self.text(request, "project"),
                                        prompt: Self.text(request, "prompt"), effort: Self.text(request, "effort"))
        if order.prompt == nil, order.effort != nil {
            return .failure("effort needs a prompt, because an empty workspace has no opening chat to apply it to.")
        }
        if let prompt = order.prompt, prompt.utf8.count > CloudWorkspaceOrder.promptLimit {
            return .failure("The prompt is longer than 512 KB. Write a shorter one, and put the rest in a file in the repository.")
        }
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
                "note": .string(order.prompt == nil
                    ? "Created empty: no agent is working in it. Give the person the url to open it."
                    : "Created. Its agent starts on the prompt once setup has run, which takes minutes. Give the person the url."),
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

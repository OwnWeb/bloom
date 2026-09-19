import Foundation

/// What an agent asked for when it asked for a Bloom Cloud workspace, once read and checked.
///
/// The same six arguments a machine's `cloud_workspace_start` takes, spelled the same way, so an
/// agent that has used one has used the other. Agreed with the Runner rather than chosen here.
public struct CloudWorkspaceOrder: Sendable, Hashable {
    /// What to call it. Nil derives it from the prompt, the way the create sheet does.
    public let name: String?
    /// The branch to cut. Nil derives it from the prompt, or from the name where there is none.
    public let branch: String?
    /// What to cut it from. Nil is the project's own default.
    public let baseBranch: String?
    /// The opening instruction, sent as the first message once the machine is up. Nil makes an
    /// empty workspace, which is what a machine's own copy of this tool does in its first version.
    public let prompt: String?
    /// Whether the machine runs the project's setup. True when the call says nothing, which is
    /// what every workspace made from the sheet already does.
    public let runSetup: Bool
    /// A runbloom.app project, by id or by its repository. Nil means "the one that is this
    /// workspace's repository", which only a caller standing in a workspace can mean.
    public let project: String?
    /// The caller's own repository as GitHub names it, `owner/name`, when the caller is standing
    /// in a workspace whose repository is on GitHub. What a nil `project` is matched against.
    public let callerRepository: String?
    /// The workspace whose agent asked, by name, for the question Bloom asks the owner. Nil for
    /// the owner's own client. See `CloudWorkspaceStartQuestion`.
    public let requestedBy: String?

    public init(
        name: String? = nil, branch: String? = nil, baseBranch: String? = nil, prompt: String? = nil,
        runSetup: Bool = true, project: String? = nil, callerRepository: String? = nil,
        requestedBy: String? = nil
    ) {
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.prompt = prompt
        self.runSetup = runSetup
        self.project = project
        self.callerRepository = callerRepository
        self.requestedBy = requestedBy
    }
}

/// What the tool answers once the workspace exists. The same four fields a machine returns.
///
/// **Returned as soon as it exists, which is minutes before it is usable.** The machine is still
/// being made; `state` says so, and nothing here invites the caller to wait for it.
public struct StartedCloudWorkspace: Sendable, Hashable {
    public let id: String
    public let name: String
    public let state: String
    /// The web address a person opens to be in it. Nil where this client does not know the
    /// route, which is better than an address somebody guessed.
    public let url: String?

    public init(id: String, name: String, state: String, url: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.url = url
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "state": .string(state),
        ]
        if let url { fields["url"] = .string(url) }
        return .object(["workspace": .object(fields)])
    }
}

/// How the window answers a request the tool has already checked.
public enum CloudWorkspaceStartOutcome: Sendable, Hashable {
    case started(StartedCloudWorkspace)
    /// Why not, in a sentence the agent can pass on: no account, no such project, a branch git
    /// will not take, runbloom.app saying no.
    case refused(String)
}

public typealias CloudWorkspaceStarting = @Sendable (CloudWorkspaceOrder) async -> CloudWorkspaceStartOutcome
/// Whether the owner has let agents do this at all. Asked on every call rather than once, so the
/// switch takes effect on the next call rather than the next launch.
public typealias CloudWorkspaceStartAllowed = @Sendable () async -> Bool

/// `cloud_workspace_start`: an agent asking for a Bloom Cloud workspace.
///
/// **A machine, not a worktree, and it costs money.** Everything else about it follows from that.
///
/// **Behind a setting that is off by default, and refused rather than absent when it is off.** An
/// agent that finds no such tool cannot tell the person where the switch is; one that is told
/// "this is off, and here is the setting" can. The setting is a preference a well behaved client
/// respects, not an authorisation: anything holding the owner's sign in can create workspaces with
/// it on or off, exactly as the owner can. The owner chose it that way knowing so.
///
/// **Not on `BridgeToolApproval`'s list, so Bloom never answers the ask itself.** That list is for
/// tools where there is nothing for a person to weigh; a tool that spends money is one a person
/// answers for, the same argument that keeps `workspace_archive` off it. **What that buys depends on
/// the chat, and it is not a promise that the owner is asked.** The ask is the agent CLI's own
/// permission check, so a chat that asks before using tools asks the owner before each one, and a
/// chat set to bypass permissions asks nobody. So Bloom asks as well, in its own window and
/// whatever the chat is set to, unless the owner has turned that off: see
/// `CloudWorkspaceStartQuestion`, which the app half asks once the order is worked out.
///
/// **One level, like `workspace_start`.** A workspace an agent started may not start more of
/// either kind: the lock that stops a runaway agent cutting worktrees stops it making machines.
///
/// **Nothing about the window moves.** The new workspace appears in the sidebar and is not
/// selected; moving somebody's selection on an agent's word is a bigger liberty than adding a row.
public struct CloudWorkspaceStartTool: BridgeToolHandling {
    private let start: CloudWorkspaceStarting
    private let allowed: CloudWorkspaceStartAllowed
    private let repositoryOf: @Sendable (String) async -> String?

    /// - Parameter repositoryOf: `owner/name` for a checkout on this Mac. Injected so the tests
    ///   need no git remote; the app's is `GitHub.repositorySlug(repoPath:)`.
    public init(
        allowed: @escaping CloudWorkspaceStartAllowed,
        start: @escaping CloudWorkspaceStarting,
        repositoryOf: @escaping @Sendable (String) async -> String? = { await GitHub.repositorySlug(repoPath: $0) }
    ) {
        self.allowed = allowed
        self.start = start
        self.repositoryOf = repositoryOf
    }

    /// The label the setting is shown under, which the refusal names so a person can find it.
    public static let settingTitle = "Let agents create Bloom Cloud workspaces"

    /// Where it is kept. Off when absent, which is every Mac until somebody turns it on.
    public static let settingKey = "bridge.allowsCloudWorkspaceStart"

    /// What a call is told while the setting is off. It names the tab and the switch, because an
    /// agent told only "not allowed" cannot help the person find where to allow it.
    public static let offSentence = """
        Creating Bloom Cloud workspaces is off. The owner turns it on in Bloom's Settings, under \
        Bloom Cloud: "\(settingTitle)". It is off by default because each one is a machine and \
        costs money.
        """

    public let roles: Set<BridgeRole> = [.workspace, .owner]

    public let tool = BridgeTool(
        name: "cloud_workspace_start",
        description: """
            Create a Bloom Cloud workspace: its own branch, its own agent, on a machine that \
            runbloom.app runs rather than on this Mac. It appears in Bloom's sidebar for the owner \
            to open, and is not brought to the front.

            This costs real money, because every Bloom Cloud workspace is a machine. The owner has \
            to have turned "\(settingTitle)" on in Bloom's Settings. Create one only when the owner \
            would want to pay for it. Create one because the work belongs on a machine: it should keep going while \
            this Mac sleeps, or somebody else on the team should be able to open it. For work that \
            belongs on this Mac, use workspace_start. Bloom may ask the owner before creating \
            it; if they decline, nothing is created and you should not ask again unless they say so.

            Give it a 'prompt' and it is sent as the first message once the machine is up. Leave \
            the prompt out to make an empty workspace, and then 'name' is required. With a prompt, \
            leave 'name' and 'branch' out and Bloom derives both from it, as its own create sheet \
            does.

            'project' is a runbloom.app project. Inside a Bloom workspace, leave it out to use the \
            project whose repository is this workspace's. 'run_setup' is true unless you say false; \
            false makes it usable sooner, without the project's setup.

            It returns as soon as the workspace exists, which is minutes before it is ready. There \
            is no way to wait for it from here: say what you created and carry on.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The opening instruction, sent once the machine is up. Write it for someone "
                            + "with no context beyond the project."
                    ),
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string("What to call it. Required without a prompt."),
                ]),
                "branch": .object([
                    "type": .string("string"),
                    "description": .string("The branch to cut. Leave it out to derive it."),
                ]),
                "base_branch": .object([
                    "type": .string("string"),
                    "description": .string("What to cut it from. Leave it out for the project's default."),
                ]),
                "run_setup": .object([
                    "type": .string("boolean"),
                    "description": .string("Whether the machine runs the project's setup. True by default."),
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string(
                        "A runbloom.app project, by id or by its repository as owner/name. Inside a "
                            + "Bloom workspace, leave it out for this workspace's repository."
                    ),
                ]),
            ]),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard await allowed() else { return .failure(Self.offSentence) }

        let prompt = filled(request.stringParam("prompt"))
        let name = filled(request.stringParam("name"))
        guard prompt != nil || name != nil else {
            return .failure(
                "cloud_workspace_start needs a prompt saying what the workspace should do, or a "
                    + "name for an empty one."
            )
        }
        let runSetup: Bool
        switch request.param("run_setup") {
        case nil, .null: runSetup = true
        case .bool(let value)?: runSetup = value
        default: return .failure("'run_setup' is true or false.")
        }

        var callerRepository: String?
        var requestedBy: String?
        if let workspaceID = identity.workspaceID {
            do {
                guard let caller = try await store.workspace(id: workspaceID) else {
                    return .failure("This workspace is no longer in Bloom's database.")
                }
                // The nesting limit, in `workspace_start`'s words, because it is the same lock.
                if caller.origin.isAgentSpawned {
                    return .failure(
                        "This workspace was itself started by an agent, and those cannot start more. "
                            + "Do the work here, or report back and let the owner decide."
                    )
                }
                requestedBy = "\u{201C}\(caller.name)\u{201D}"
                if let repo = try await store.repo(id: caller.repoID) {
                    callerRepository = await repositoryOf(repo.path)
                }
            } catch {
                return .failure("Bloom could not read this workspace: \(error.readableMessage)")
            }
        }

        let order = CloudWorkspaceOrder(
            name: name, branch: filled(request.stringParam("branch")),
            baseBranch: filled(request.stringParam("base_branch")), prompt: prompt,
            runSetup: runSetup, project: filled(request.stringParam("project")),
            callerRepository: callerRepository, requestedBy: requestedBy
        )
        switch await start(order) {
        case .started(let workspace): return .json(workspace.json)
        case .refused(let sentence): return .failure(sentence)
        }
    }

    private func filled(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

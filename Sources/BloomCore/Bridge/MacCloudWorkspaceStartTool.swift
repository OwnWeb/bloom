import Foundation

/// The current Runner order, plus the two facts only the Mac knows when it resolves a project and
/// asks the owner. Keeping the wire-shaped order whole makes the Mac and Runner tools accept the
/// same arguments without putting Mac-only state on the Runner request.
public struct MacCloudWorkspaceOrder: Sendable, Equatable {
    public let order: CloudWorkspaceOrder
    /// The creating chat's controls, when there is one. Nil for an owner client with no chat.
    public let callerControls: ComposerControls?
    /// The caller's own repository as GitHub names it, `owner/name`, when the caller is standing
    /// in a workspace whose repository is on GitHub. What a nil `project` is matched against.
    public let callerRepository: String?
    /// The workspace whose agent asked, by name, for the question Bloom asks the owner. Nil for
    /// the owner's own client. See `CloudWorkspaceStartQuestion`.
    public let requestedBy: String?

    public init(
        order: CloudWorkspaceOrder,
        callerControls: ComposerControls? = nil,
        callerRepository: String? = nil,
        requestedBy: String? = nil
    ) {
        self.order = order
        self.callerControls = callerControls
        self.callerRepository = callerRepository
        self.requestedBy = requestedBy
    }
}

public typealias MacCloudWorkspaceStarting = @Sendable (MacCloudWorkspaceOrder) async -> CloudWorkspaceAnswer
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
public struct MacCloudWorkspaceStartTool: BridgeToolHandling {
    private let start: MacCloudWorkspaceStarting
    private let allowed: CloudWorkspaceStartAllowed
    private let repositoryOf: @Sendable (String) async -> String?

    /// - Parameter repositoryOf: `owner/name` for a checkout on this Mac. Injected so the tests
    ///   need no git remote; the app's is `GitHub.repositorySlug(repoPath:)`.
    public init(
        allowed: @escaping CloudWorkspaceStartAllowed,
        start: @escaping MacCloudWorkspaceStarting,
        repositoryOf: @escaping @Sendable (String) async -> String? = { await GitHub.repositorySlug(repoPath: $0) }
    ) {
        self.allowed = allowed
        self.start = start
        self.repositoryOf = repositoryOf
    }

    /// The label the setting is shown under, which the refusal names so a person can find it.
    public static let settingTitle = "Let agents on this Mac create Bloom Cloud workspaces"

    /// Where it is kept. Off when absent, which is every Mac until somebody turns it on.
    public static let settingKey = "bridge.allowsCloudWorkspaceStart"

    /// What a call is told while the setting is off. It names the tab and the switch, because an
    /// agent told only "not allowed" cannot help the person find where to allow it.
    public static let offSentence = """
        Creating Bloom Cloud workspaces is off. The owner turns it on in Bloom's Settings, under \
        Permissions, Cloud workspaces: "\(settingTitle)". It is off by default because each one is a machine and \
        costs money.
        """

    public let roles: Set<BridgeRole> = [.workspace, .owner]

    public let tool = BridgeTool(
        name: CloudWorkspaceStartTool.name,
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
            the prompt out to make an empty workspace. 'name' is always required, as it is when \
            the same tool runs on a Bloom Cloud machine.

            Pass 'effort' to choose the opening chat's reasoning effort, or leave it out to use \
            the effort of the chat making this call. An empty workspace has no opening chat, so \
            it takes no effort.

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
                "effort": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The opening chat's exact reasoning effort id, such as low, medium or "
                            + "high. Leave it out to inherit the creating chat's effort."
                    ),
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string("What to call it. Short, and saying what it is for."),
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
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard await allowed() else { return .failure(Self.offSentence) }

        let prompt = CloudWorkspaceStartTool.text(request, "prompt")
        let effort = CloudWorkspaceStartTool.text(request, "effort")
        guard let name = CloudWorkspaceStartTool.text(request, "name") else {
            return .failure("Give the new workspace a name.")
        }
        if let prompt, prompt.utf8.count > CloudWorkspaceOrder.promptLimit {
            return .failure("The prompt is longer than 512 KB. Write a shorter one, and put the rest in a file in the repository.")
        }
        if prompt == nil, effort != nil {
            return .failure("effort needs a prompt, because an empty workspace has no opening chat to apply it to.")
        }
        let runSetup: Bool
        switch request.param("run_setup") {
        case nil, .null: runSetup = true
        case .bool(let value)?: runSetup = value
        default: return .failure("'run_setup' is true or false.")
        }

        var callerRepository: String?
        var requestedBy: String?
        var callerControls: ComposerControls?
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
        if prompt != nil, let sessionID = identity.sessionID {
            do {
                guard let session = try await store.session(id: sessionID) else {
                    return .failure("This chat is no longer open in Bloom, so its composer settings cannot be handed over.")
                }
                let fast = try await store.setting(ComposerControls.fastModeKey(sessionID: sessionID)) == "1"
                let output = try await store.setting(ComposerControls.outputStyleKey(sessionID: sessionID))
                    ?? OutputStyle.defaultName
                let contextWindow = CodexContextWindow.normalised(
                    try await store.setting(ComposerControls.contextWindowKey(sessionID: sessionID))
                )
                let codexFastMode = CodexSpeed.override(stored: try await store.setting(
                    CodexSpeed.key(sessionID: sessionID)
                ))
                callerControls = ComposerControls(
                    session: session,
                    isFastMode: fast,
                    outputStyle: output,
                    codexContextWindow: contextWindow,
                    codexFastMode: codexFastMode
                )
            } catch {
                return .failure("Bloom could not read this chat's composer settings: \(error.readableMessage)")
            }
        }

        let order = MacCloudWorkspaceOrder(
            order: CloudWorkspaceOrder(
                name: name, branch: CloudWorkspaceStartTool.text(request, "branch"),
                baseBranch: CloudWorkspaceStartTool.text(request, "base_branch"), runSetup: runSetup,
                project: CloudWorkspaceStartTool.text(request, "project"), prompt: prompt, effort: effort
            ),
            callerControls: callerControls,
            callerRepository: callerRepository, requestedBy: requestedBy
        )
        switch await start(order) {
        case .created(let workspace):
            return .json(.object([
                "id": .string(workspace.id), "name": .string(workspace.name),
                "state": .string(workspace.state), "url": .string(workspace.url),
                "note": .string(prompt == nil
                    ? "Created empty: no agent is working in it. Give the person the url to open it."
                    : "Created. Its agent starts on the prompt once setup has run, which takes minutes. Give the person the url."),
            ]))
        case .refused(let sentence): return .failure(sentence)
        }
    }
}

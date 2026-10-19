import Foundation

/// Why `workspace_hold` would not act, said so a model can do something about it.
public enum WorkspaceHoldTrouble: Error, Sendable, Equatable {
    case notABool
    case noWorkspaceNamed
    case unknown(given: String, known: [String])
    case ambiguous(given: String, ids: [String])
    case notInAWorkspace
    case gone
    /// Something in the workspace is still going, which a folded On hold would hide.
    case busy(String)
    case unexplained(String)

    public var sentence: String {
        switch self {
        case .notABool:
            return "workspace_hold takes 'on_hold' as true or false, or nothing for true."
        case .noWorkspaceNamed:
            return """
                workspace_hold needs to be told which workspace, because this connection is not \
                sitting in one. Pass 'workspace' with the name or the id workspace_list prints.
                """
        case let .unknown(given, known):
            guard !known.isEmpty else {
                return "Bloom has no active workspaces, so there is nothing called '\(given)'."
            }
            return """
                Bloom has no active workspace called '\(given)'. It has \
                \(BridgeWorkspaceLookup.list(known)). Pass one of those names, or an id reported by \
                workspace_list.
                """
        case let .ambiguous(given, ids):
            return """
                \(ids.count) workspaces are called '\(given)'. Pass one of these ids instead: \
                \(BridgeWorkspaceLookup.list(ids)).
                """
        case .notInAWorkspace:
            return BridgeWorkspaceScope.refusal(tool: "workspace_hold", doing: "holds")
        case .gone:
            return "That workspace is no longer in Bloom, so nothing changed."
        case .busy(let reason):
            return "Nothing was put on hold. \(reason)"
        case .unexplained(let message):
            return "Bloom could not change that workspace: \(message)"
        }
    }
}

/// Whether anything in a workspace is still going, which putting it on hold would fold away.
public enum WorkspaceHoldSafety {
    /// The sentence to refuse with, or nil. `excusing` is the chat whose own turn is asking.
    public static func objection(
        to workspace: Workspace, excusing asking: SessionID?, store: Store
    ) async -> String? {
        do {
            for session in try await store.sessions(workspaceID: workspace.id) {
                if session.id != asking, session.state == .running || session.state == .waiting {
                    return "An agent is running or awaiting an answer in this workspace. Ask again once it has finished."
                }
                if try await !store.pendingDeliveries(sessionID: session.id).isEmpty {
                    return "This workspace has queued messages, so its work is about to start again."
                }
            }
        } catch {
            return "Bloom could not check this workspace's activity; try again shortly."
        }
        return nil
    }
}

/// The app's half: holding a workspace's own request until the turn asking ends, which only the
/// window sees. A nil chat withdraws a request made earlier.
public typealias WorkspaceHoldBooking = @Sendable (WorkspaceID, SessionID?) async -> Void

/// `workspace_hold`: put a workspace on hold while somebody else has the next move, or bring it
/// back, so an agent that has just asked for a review can step out of the owner's way itself.
///
/// One tool for both ways, like the row menu's one item. Its own workspace is held only once the
/// asking turn has ended, as `workspace_archive` does: held mid turn, a permission question asked
/// afterwards would wait unseen under a folded On hold. Any other workspace changes at once, and
/// may be named out loud like `workspace_rename`, because nothing on disk moves either way.
public struct WorkspaceHoldTool: BridgeToolHandling {
    private let book: WorkspaceHoldBooking

    public init(_ book: @escaping WorkspaceHoldBooking) {
        self.book = book
    }

    public let roles: Set<BridgeRole> = [.workspace, .owner]

    public let tool = BridgeTool(
        name: "workspace_hold",
        description: """
            Put a workspace on hold, or take it off hold. A workspace on hold leaves its project \
            in the sidebar for a folded On hold section at the bottom, so the owner sees only the \
            work in progress. Use it once the next move is somebody else's, typically after asking \
            a person for a review. Any message sent to a workspace takes it off hold again.

            'on_hold' is true to put it on hold, which is the default, or false to bring it back \
            without sending it anything.

            If you are working in a workspace, leave 'workspace' out to act on yours. Yours is put \
            on hold when this turn ends, not now, so finish what you have to say in this turn. \
            Pass the name or id of any other workspace to act on it at once; one with an agent \
            running or messages queued is refused. From a client of the owner's own, 'workspace' \
            is required.

            Nothing on disk changes either way, and calling again with the opposite value undoes it.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "on_hold": .object([
                    "type": .string("boolean"),
                    "description": .string("True to put the workspace on hold, false to take it off. Defaults to true."),
                ]),
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Which workspace, by name or id. Leave it out to act on your own. Required from the owner's own client."
                    ),
                ]),
            ]),
        ])
    )

    public func call(
        _ request: MCPRequest, as identity: BridgeIdentity, store: Store
    ) async -> BridgeToolResult {
        guard let onHold = wanted(request) else { return .failure(WorkspaceHoldTrouble.notABool.sentence) }

        let workspace: Workspace
        switch await find(named: WorkspaceName.given(request.stringParam("workspace")), as: identity, store: store) {
        case .failure(let trouble): return .failure(trouble.sentence)
        case .success(let found): workspace = found
        }

        if onHold, identity.role == .workspace, workspace.id == identity.workspaceID {
            guard let asking = identity.sessionID else { return .failure(WorkspaceHoldTrouble.notInAWorkspace.sentence) }
            return await bookOwn(workspace, asking: asking, store: store)
        }
        // A request booked earlier in this turn must not land after being taken back.
        if !onHold { await book(workspace.id, nil) }

        guard workspace.onHold != onHold else {
            return .json(answer(workspace, onHold: onHold, note: onHold
                ? "It was already on hold, so nothing changed."
                : "It was not on hold, so nothing changed."))
        }
        if onHold, let objection = await WorkspaceHoldSafety.objection(to: workspace, excusing: nil, store: store) {
            return .failure(WorkspaceHoldTrouble.busy(objection).sentence)
        }
        do {
            guard try await store.update(workspaceID: workspace.id, { $0.onHold = onHold }) != nil else {
                return .failure(WorkspaceHoldTrouble.gone.sentence)
            }
        } catch {
            return .failure(WorkspaceHoldTrouble.unexplained(error.readableMessage).sentence)
        }
        return .json(answer(workspace, onHold: onHold, note: onHold
            ? "It is on hold now, folded away at the bottom of the sidebar. Call again with on_hold false to bring it back."
            : "It is back in its project in the sidebar."))
    }

    private func bookOwn(_ workspace: Workspace, asking: SessionID, store: Store) async -> BridgeToolResult {
        if let objection = await WorkspaceHoldSafety.objection(to: workspace, excusing: asking, store: store) {
            return .failure(WorkspaceHoldTrouble.busy(objection).sentence)
        }
        await book(workspace.id, asking)
        return .json(answer(workspace, onHold: true, note: """
            Requested, not done: this workspace goes on hold when this turn ends, unless a message \
            is queued for it by then. Finish what you have to say now. The next message anybody \
            sends it brings it back.
            """))
    }

    /// True when the argument is missing, nil when it is there and not a boolean.
    private func wanted(_ request: MCPRequest) -> Bool? {
        guard case .object(let arguments)? = request.params, let value = arguments["on_hold"] else { return true }
        guard case .bool(let onHold) = value else { return nil }
        return onHold
    }

    /// Its own when a workspace agent names none; the owner's client must name one. Active
    /// workspaces only, because the sidebar never lists an archived one.
    private func find(
        named: String?, as identity: BridgeIdentity, store: Store
    ) async -> Result<Workspace, WorkspaceHoldTrouble> {
        do {
            guard let named else {
                guard identity.role != .owner else { return .failure(.noWorkspaceNamed) }
                guard let workspaceID = identity.workspaceID else { return .failure(.notInAWorkspace) }
                guard let own = try await store.workspace(id: workspaceID) else { return .failure(.gone) }
                return .success(own)
            }
            let workspaces = try await store.workspaces(includeArchived: false)
            switch BridgeWorkspaceLookup.find(named, among: workspaces) {
            case .found(let workspace): return .success(workspace)
            case .unknown: return .failure(.unknown(given: named, known: workspaces.map(\.name)))
            case .ambiguous(let matches): return .failure(.ambiguous(given: named, ids: matches.map(\.id.rawValue)))
            }
        } catch {
            return .failure(.unexplained(error.readableMessage))
        }
    }

    private func answer(_ workspace: Workspace, onHold: Bool, note: String) -> JSONValue {
        .object([
            "workspace_id": .string(workspace.id.rawValue),
            "name": .string(workspace.name),
            "on_hold": .bool(onHold),
            "note": .string(note),
        ])
    }
}

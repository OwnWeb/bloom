#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// An agent's `cloud_workspace_start`, with what only the machine knows added: the turn it is
/// running in, and the key that makes asking twice make one workspace.
public struct CloudWorkspaceRequest: Sendable, Hashable {
    public var order: CloudWorkspaceOrder
    /// runbloom.app's own id for the turn, which is how it knows who is asking. See
    /// `WorkspaceRuntime.startCloudWorkspace`.
    public var turnID: String
    public var idempotencyKey: String
    /// The creating chat's agent, model and effort, sent with a prompt so the opening turn runs on
    /// what the person was already using. The agent and model cannot be overridden here; effort may
    /// be explicitly changed to another value that model offers. Nil without a prompt.
    public var agent: String?
    public var model: String?
    public var effort: String?

    public init(
        order: CloudWorkspaceOrder,
        turnID: String,
        idempotencyKey: String,
        agent: String? = nil,
        model: String? = nil,
        effort: String? = nil
    ) {
        self.order = order
        self.turnID = turnID
        self.idempotencyKey = idempotencyKey
        self.agent = agent
        self.model = model
        self.effort = effort
    }

    /// **The turn and the name, not the call.** A key per call would stop the machine's own retry
    /// making two workspaces and nothing else; the retry that costs money is the agent's, which is
    /// a second call after a first that timed out, and it asks for the same name in the same turn.
    /// runbloom.app answers a repeated key with the workspace it already made, and refuses one
    /// whose body differs, so an agent that asks for the same name twice with different branches
    /// is told rather than quietly handed the first.
    public static func idempotencyKey(turnID: String, name: String) -> String {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data("\(turnID)\n\(folded)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension WorkspaceRuntime {
    func stopCloudWorkspace(_ workspace: String?, sessionID: SessionID?) async -> CloudWorkspaceStopAnswer {
        guard let stopCloudWorkspace else {
            return .refused("This machine is not connected to runbloom.app, so it cannot stop a Bloom Cloud workspace.")
        }
        switch await personsTurn(sessionID, doing: "stop a Bloom Cloud workspace") {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let turnID):
            return await stopCloudWorkspace(CloudWorkspaceStopRequest(turnID: turnID, workspace: workspace))
        }
    }

    /// Asks runbloom.app for another Cloud workspace, as the person whose turn this is.
    ///
    /// **Only a turn a person started can ask.** runbloom.app decides who is asking from the turn,
    /// never from a name the machine sends, so that a machine can only ever act as whoever is
    /// prompting it. A crew member's chat runs turns nobody registered, and a chat between turns
    /// has none, so both are refused here rather than sent with a guess; runbloom.app refuses a
    /// turn with nobody behind it as well, because a rule the server holds cannot be skipped by a
    /// machine that forgot it.
    func startCloudWorkspace(_ order: CloudWorkspaceOrder, sessionID: SessionID?) async -> CloudWorkspaceAnswer {
        guard let createCloudWorkspace else {
            return .refused("This machine is not connected to runbloom.app, so it cannot create a Bloom Cloud workspace.")
        }
        guard let sessionID, let turnID = await promptQueue?.runningTurn(sessionID) else {
            return .refused("Only a chat a person is prompting can create a Bloom Cloud workspace, because it is "
                + "created as that person and they pay for it. Ask from the chat they wrote to.")
        }
        var request = CloudWorkspaceRequest(
            order: order, turnID: turnID,
            idempotencyKey: CloudWorkspaceRequest.idempotencyKey(turnID: turnID, name: order.name)
        )
        if order.prompt != nil, let session = try? await store.session(id: sessionID) {
            // runbloom.app starts an opening turn with a Claude Code or a Codex key and nothing else.
            guard [.claudeCode, .codex].contains(session.agentKind) else {
                return .refused("Only a Claude Code or Codex chat can hand a new Bloom Cloud workspace its first task. "
                    + "Create it without a prompt, and the person can write the first message there.")
            }
            request.agent = session.agentKind.wireName
            request.model = session.model
            if let effort = order.effort {
                guard let workspace = try? await workspace() else {
                    return .refused("This machine could not read its workspace, so it cannot verify that reasoning effort.")
                }
                let listed = await models(workspace.path)
                let offered = listed.first {
                    $0.agent == session.agentKind.wireName && $0.id == session.model
                }
                let available = offered?.efforts ?? (session.agentKind == .claudeCode
                    ? Array(Set(listed.filter { $0.agent == session.agentKind.wireName }.flatMap(\.efforts))).sorted()
                    : [])
                guard available.contains(effort) else {
                    let choices = available.isEmpty ? "none" : available.joined(separator: ", ")
                    return .refused("The current model does not offer reasoning effort '\(effort)'. Available efforts: \(choices).")
                }
                request.effort = effort
            } else {
                request.effort = session.effort
            }
        }
        return await createCloudWorkspace(request)
    }
}

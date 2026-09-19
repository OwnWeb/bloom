import Foundation

/// Another Bloom Cloud workspace in this team, as runbloom.app lists it for the person whose turn
/// is running.
public struct PeerWorkspace: Sendable, Hashable {
    public var id: String
    public var name: String
    public var state: String

    public init(id: String, name: String, state: String) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public enum PeerListAnswer: Sendable, Hashable {
    case listed([PeerWorkspace])
    case refused(String)
}

/// What an agent here asks to say to another workspace, with what only this machine knows added.
public struct PeerMessage: Sendable, Hashable {
    /// runbloom.app's turn, which is how it knows who is asking. See `WorkspaceRuntime.startCloudWorkspace`.
    public var turnID: String
    /// An id or a name, as the agent wrote it.
    public var workspace: String
    /// A chat on the other side, by id or exact title, or nil for its most recent top-level chat.
    public var chat: String?
    public var text: String
    /// This workspace's name and the sending chat's title, drawn there under the author.
    public var via: MessageVia

    public init(turnID: String, workspace: String, chat: String?, text: String, via: MessageVia) {
        self.turnID = turnID
        self.workspace = workspace
        self.chat = chat
        self.text = text
        self.via = via
    }
}

public enum PeerSayAnswer: Sendable, Hashable {
    /// Sent into `chat` of `workspace`; `queued` when a turn was running there and it waits.
    case sent(workspace: String, chat: String, queued: Bool)
    case refused(String)
}

/// Reaching the team's other Bloom Cloud workspaces: runbloom.app mints a short token for the other
/// machine, as the person whose turn is running, and this machine talks to that one directly.
/// runbloom.app is the authority and never the pipe. See docs/CLOUD-PARITY.md.
public struct WorkspacePeers: Sendable {
    public var list: @Sendable (_ turnID: String) async -> PeerListAnswer
    public var say: @Sendable (PeerMessage) async -> PeerSayAnswer

    public init(list: @escaping @Sendable (String) async -> PeerListAnswer,
                say: @escaping @Sendable (PeerMessage) async -> PeerSayAnswer) {
        self.list = list
        self.say = say
    }
}

extension WorkspaceRuntime {
    /// The turn a person started in this chat, or the sentence that says why there is none. A
    /// crew member's chat runs turns nobody registered, and runbloom.app decides who is asking
    /// from the turn, so both tools refuse there before anything is sent.
    func personsTurn(_ sessionID: SessionID?, doing what: String) async -> Result<String, RemoteFailure> {
        guard let sessionID, let turnID = await promptQueue?.runningTurn(sessionID) else {
            return .failure(RemoteFailure.invalid("Only a chat a person is prompting can \(what), because it is done "
                + "as that person. Ask from the chat they wrote to."))
        }
        return .success(turnID)
    }

    func listPeers(sessionID: SessionID?) async -> PeerListAnswer {
        guard let peers else { return .refused(Self.notConnected) }
        switch await personsTurn(sessionID, doing: "list the team's other workspaces") {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let turnID): return await peers.list(turnID)
        }
    }

    func sayToPeer(workspace: String, chat: String?, text: String, sessionID: SessionID?) async -> PeerSayAnswer {
        guard let peers else { return .refused(Self.notConnected) }
        switch await personsTurn(sessionID, doing: "message another workspace") {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let turnID):
            // Names rather than ids: the other machine only ever draws them, and this workspace's id
            // means nothing there.
            let here = try? await self.workspace()
            let sender: Session? = if let sessionID { try? await store.session(id: sessionID) } else { nil }
            let via = MessageVia(workspace: here?.name, chat: sender?.title)
            return await peers.say(PeerMessage(turnID: turnID, workspace: workspace, chat: chat, text: text, via: via))
        }
    }

    static let notConnected = "This machine is not connected to runbloom.app, so it cannot reach another workspace."
}

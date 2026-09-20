import BloomProtocol
import Foundation

public enum MacSayAnswer: Sendable, Hashable {
    /// Sent down this many of the person's connections to this workspace.
    case sent(connections: Int)
    /// Left with runbloom.app for their Mac to collect, because no Mac of theirs had this workspace
    /// open. `expiresAt` is when it is dropped uncollected, as runbloom.app said it.
    case queued(expiresAt: String?)
    case refused(String)
}

/// A message left with runbloom.app for a Mac that is not connected. runbloom.app delivers it to the
/// turn's person and nobody else, so it names no recipient. See `WorkspacePeers.depositForMac`.
public struct MacDeposit: Sendable, Hashable {
    public var turnID: String
    public var workspace: String
    public var text: String
    public var chat: String?
    /// One per tool call and kept across that call's retries, so a lost answer queues nothing twice.
    public var idempotencyKey: String

    public init(turnID: String, workspace: String, text: String, chat: String?, idempotencyKey: String) {
        self.turnID = turnID
        self.workspace = workspace
        self.text = text
        self.chat = chat
        self.idempotencyKey = idempotencyKey
    }
}

// An agent here telling its person's Mac something, for a workspace on that Mac. See "Bloom Cloud
// to a Mac" in docs/CLOUD-PARITY.md: down the streams that Mac opened, and only those.
extension WorkspaceRuntime {
    /// What Bloom on a Mac names itself when it opens the event stream, in `Bloom-Client`.
    public static let macClient = "mac"

    /// **The person is the turn's, never the agent's to say.** runbloom.app registered the turn
    /// under them, so the message can only ever reach the Mac of whoever is prompting this chat: a
    /// colleague prompting the same workspace reaches their own Mac and no other. A crew chat has
    /// no person and is refused, and so is a team that has not switched messaging on, which is the
    /// question runbloom.app answers before any workspace-to-workspace message.
    func sayToMac(workspace: String, text: String, sessionID: SessionID?) async -> MacSayAnswer {
        guard let peers else { return .refused(Self.notConnected) }
        let turnID: String
        switch await personsTurn(sessionID, doing: "message a workspace on its person's Mac") {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let running): turnID = running
        }
        guard let sessionID, let person = await promptQueue?.runningAuthor(sessionID), !person.hasPrefix("share:") else {
            return .refused("Only a member of the team can be sent a message on their Mac.")
        }
        // The same switch and the same checks as messaging another Bloom Cloud workspace.
        if case .refused(let sentence) = await peers.list(turnID) { return .refused(sentence) }

        let here = try? await self.workspace()
        let sender = try? await store.session(id: sessionID)
        let record = MacMessageRecord(
            id: UUID().uuidString.lowercased(), userID: person, workspace: workspace, text: text,
            via: MessageVia(workspace: here?.name, chat: sender?.title).record
        )
        // A Mac's own streams only: a browser holding the same person's stream is not a Mac.
        let told = await events.publish(.macMessage(record), toUser: person, client: Self.macClient)
        guard told > 0 else {
            // **Direct first, and left with runbloom.app only when no Mac of theirs is here.** A
            // browser tab on this workspace does not count: it cannot reach a local workspace. The
            // second written exception to runbloom.app never carrying the words, approved by Freek.
            if let deposit = peers.depositForMac {
                return await deposit(MacDeposit(turnID: turnID, workspace: workspace, text: text,
                                                chat: sender?.title, idempotencyKey: record.id))
            }
            return .refused("Their Mac is not connected to this workspace right now, so nothing was sent. "
                + "It reaches them only while they have this workspace open in Bloom on their Mac.")
        }
        return .sent(connections: told)
    }
}

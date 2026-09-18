import BloomProtocol
import Foundation

/// One person, addressed in one message, and whether runbloom.app has been told.
///
/// **A row per message and addressed person, because that is what the mail is deduped on.** A
/// partial delivery or a corrected audience is exactly where a per-message identifier would double
/// mail somebody or lose them, so the unit here is the unit at the other end.
///
/// **It is a table rather than something held in memory, because a machine that restarts between
/// writing the message and telling runbloom.app would otherwise never tell it**, and nobody would
/// be mailed. The row survives, so the report is retried after the restart with the same id.
///
/// **`id` is minted once and never reused.** runbloom.app treats a repeat as a retry and mails
/// nobody, so a reused id fails silently, which is the worst way for this to fail.
public struct AddressedReport: Sendable, Hashable {
    /// Who addressed somebody: a member, or a guest who came in through a share link. A guest's is
    /// reported too, and **runbloom.app decides that a guest's message sends no mail**: the machine
    /// says what happened, the server decides what it means, so changing that policy is a deploy
    /// rather than a release to every machine.
    public enum Sender: Sendable, Hashable {
        case member(String)
        case guest
    }

    public var id: String
    public var sessionID: SessionID
    public var userID: String
    /// Whether they were connected to this workspace **at the moment the message was sent**, which
    /// only the machine can say.
    ///
    /// **This looks like staleness and is the opposite.** The report may go twenty minutes late,
    /// after a restart, and asking presence then would answer a different question: runbloom.app is
    /// deciding whether somebody missed a message, which depends on where they were when it
    /// arrived, not on where they are when the machine gets round to saying so. So it is recorded
    /// with the row and never refreshed.
    public var connected: Bool
    public var sentAt: Date
    public var from: Sender

    public init(id: String = newID(), sessionID: SessionID, userID: String, connected: Bool,
                sentAt: Date, from: Sender) {
        self.id = id
        self.sessionID = sessionID
        self.userID = userID
        self.connected = connected
        self.sentAt = sentAt
        self.from = from
    }

    /// The body runbloom.app reads. See `RunbloomClient.reportAddressed`.
    public var body: JSONValue {
        var sender: [String: JSONValue] = ["kind": .string(from.kind)]
        if case .member(let userID) = from { sender["user_id"] = .string(userID) }
        return .object([
            "message_id": .string(id),
            "sent_at": .string(WireDate.string(from: sentAt)),
            "from": .object(sender),
            "addressed": .array([.object(["user_id": .string(userID), "connected": .bool(connected)])]),
        ])
    }
}

extension AddressedReport.Sender {
    var kind: String {
        switch self {
        case .member: "member"
        case .guest: "guest"
        }
    }

    /// A share link needs no account and can be passed to anybody, so the subject it mints is not a
    /// person of the team. `WorkspaceToken.isShare` is the same test at the other end.
    public static func of(_ author: MessageAuthor?) -> Self {
        guard let author, !author.userID.hasPrefix("share:") else { return .guest }
        return .member(author.userID)
    }
}

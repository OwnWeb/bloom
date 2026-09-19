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
    /// The words, as typed and mention included, so the mail can say what was asked rather than
    /// only that something was. **Only the message that addressed this person**: a report is one
    /// message and one recipient, so it can never carry anybody else's words. Capped at
    /// `textLimit`. Nil on a report written before the words were kept, which is sent without them.
    public var text: String?

    public init(id: String = newID(), sessionID: SessionID, userID: String, connected: Bool,
                sentAt: Date, from: Sender, text: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.userID = userID
        self.connected = connected
        self.sentAt = sentAt
        self.from = from
        self.text = text
    }

    /// Enough for any message somebody writes to a colleague in a chat, and short enough that a
    /// mail is a nudge rather than a transcript.
    public static let textLimit = 2_000
    /// runbloom.app refuses more than 16 KiB of UTF-8. Two thousand characters are far under that
    /// in any ordinary sentence, but a character can be a long run of bytes, an emoji family among
    /// them, and a report refused for its words would mail nobody at all.
    public static let byteLimit = 16_000

    /// The first `textLimit` characters, shortened further until they fit `byteLimit`, and never
    /// cut inside a character.
    static func excerpt(_ text: String) -> String {
        var cut = String(text.prefix(textLimit))
        while cut.utf8.count > byteLimit { cut.removeLast() }
        return cut
    }

    /// The body runbloom.app reads. See `RunbloomClient.reportAddressed`.
    public var body: JSONValue {
        var sender: [String: JSONValue] = ["kind": .string(from.kind)]
        if case .member(let userID) = from { sender["user_id"] = .string(userID) }
        var body: [String: JSONValue] = [
            "message_id": .string(id),
            "sent_at": .string(WireDate.string(from: sentAt)),
            "from": .object(sender),
            "addressed": .array([.object(["user_id": .string(userID), "connected": .bool(connected)])]),
        ]
        // **Named for what it is: words one person wrote to another.** Never a prompt and never
        // agent traffic, and the key says so to whoever reads the body at the other end.
        // Only with words in it: runbloom.app refuses an empty `text`, and a refused report mails nobody.
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let excerpt = Self.excerpt(text)
            body["person_message"] = .object(["text": .string(excerpt), "truncated": .bool(excerpt != text)])
        }
        return .object(body)
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

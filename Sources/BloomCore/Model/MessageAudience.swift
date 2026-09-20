import BloomProtocol
import Foundation

/// Who a message in a chat was addressed to.
///
/// **The agent must never be given one addressed to a person.** That is the whole of the feature:
/// `@seb` at the start of a prompt means "this is for Seb, not for you", and a message the agent can
/// read is a message the feature did not deliver. Enforced where the transcript is handed out
/// rather than where a prompt is sent, because "do not deliver it" is a rule a later change that
/// helpfully replays the last few rows silently breaks. See `ChatReadTool`.
///
/// Nil on a message means the agent, which is every message written before this existed.
public struct MessageAudience: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case agent
        case person
    }

    public var kind: Kind
    /// The person it was for. **An id, never a typed name.**
    public var userID: String?
    /// The mention as typed, kept because a bubble draws it and stripped only when an agent is
    /// handed the text.
    public var mention: String?

    public init(kind: Kind, userID: String? = nil, mention: String? = nil) {
        self.kind = kind
        self.userID = userID
        self.mention = mention
    }

    public var isPrivateToPeople: Bool { kind == .person }

    public var record: AudienceRecord {
        AudienceRecord(kind: kind.rawValue, userID: userID, mention: mention)
    }

    /// From the wire. **An unknown kind is refused rather than guessed at**, because guessing
    /// "agent" would hand the agent a message meant for somebody else, which is the one outcome
    /// this type exists to prevent.
    public init?(_ record: AudienceRecord) {
        guard let kind = Kind(rawValue: record.kind) else { return nil }
        self.kind = kind
        self.userID = record.userID
        self.mention = record.mention
    }

    /// The text an agent is handed: what was typed, with the mention that addressed it removed.
    ///
    /// `@agent Fix the server` reaches the agent as `Fix the server`. The stored text keeps the
    /// mention, because the transcript draws it.
    public static func textForAgent(_ text: String, mention: String?) -> String {
        guard let mention, !mention.isEmpty, text.hasPrefix(mention) else { return text }
        return String(text.dropFirst(mention.count)).trimmingCharacters(in: .whitespaces)
    }
}

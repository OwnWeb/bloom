import Foundation

/// Who a message was addressed to, and the mention that addressed them.
///
/// **A message to a person is not a message to the agent.** `@name` at the start of a prompt in a
/// shared workspace means "this one is for Seb, not for you", and the whole feature is that the
/// agent never sees it: not filtered at the client, not marked and passed on, not included by a
/// later change that helpfully replays the last few rows. **Absent means the agent**, which is what
/// every message sent before this existed was.
///
/// **The mention is carried, not re-parsed.** Two clients that each find the `@` themselves will
/// disagree the first time somebody types `@seb.dd` or an address, and a highlight computed from an
/// offset is worse still: JavaScript counts UTF-16 code units and Swift counts graphemes, so one
/// accented name before the mention puts the two clients' highlights in different places. The
/// mention is only ever a prefix, so what travels is the text that was typed and the person it
/// resolved to, and the extent is its length. If a mention ever appears mid-message, ranges can be
/// added then, with their unit stated in the same breath.
public struct AudienceRecord: Codable, Sendable, Hashable {
    /// `agent` or `person`.
    public var kind: String
    /// Set when `kind` is `person`. **An id, never a typed name**: addressing by display name sends
    /// to the wrong person the day two people share one.
    public var userID: String?
    /// The mention as it was typed, `@sebdd` or `@agent`, kept because the bubble draws it. **The
    /// machine strips it before an agent reads the text**, so the agent is asked "Fix the server",
    /// not "@agent Fix the server"; a client must not strip it early or it vanishes from the
    /// transcript it exists to colour.
    public var mention: String?

    public init(kind: String, userID: String? = nil, mention: String? = nil) {
        self.kind = kind
        self.userID = userID
        self.mention = mention
    }

    public static let agent = "agent"
    public static let person = "person"

    /// Whether this message is one the agent must never be given.
    public var isPrivateToPeople: Bool { kind == Self.person }

    enum CodingKeys: String, CodingKey {
        case kind, mention
        case userID = "user_id"
    }
}

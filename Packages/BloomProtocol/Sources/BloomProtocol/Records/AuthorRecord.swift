import Foundation

/// Who did something, as runbloom.app named them in the token they did it with.
///
/// The id is runbloom.app's user id (a lowercase ULID), the name is for display only and is the
/// name at the time, never looked up again. Nil wherever the server acted on its own or an agent
/// did, which is why every use of this is optional.
public struct AuthorRecord: Codable, Sendable, Hashable {
    public var userID: String
    /// What to draw. **May be empty**, for somebody runbloom.app has no display name for.
    public var name: String
    /// Their address, when runbloom.app knows one. Absent for a share-link guest.
    ///
    /// **A separate field rather than an email put in `name`.** The overload is fine until
    /// something matches on it, and the thing about to match on it is mention completion, where
    /// picking the wrong person sends a message meant for one person to another. A client that
    /// wants to draw a name and copy an address also cannot tell the two apart by looking for an
    /// `@`.
    public var email: String?

    public init(userID: String, name: String, email: String? = nil) {
        self.userID = userID
        self.name = name
        self.email = email
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case name, email
    }

    /// **The rule every client should draw by: the name if it is not empty, the email if it is,
    /// and "somebody" if neither.** Written once here rather than three times in three clients,
    /// because a shared workspace where one person's messages are unlabelled reads as the reader's
    /// own, which is how a shared team address was mistaken for Freek on 18 September 2026.
    public var label: String {
        let stated = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stated.isEmpty { return stated }
        let address = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? "somebody" : address
    }
}

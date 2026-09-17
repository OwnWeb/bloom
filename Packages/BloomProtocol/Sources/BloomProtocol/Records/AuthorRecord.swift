import Foundation

/// Who did something, as runbloom.app named them in the token they did it with.
///
/// The id is runbloom.app's user id (a lowercase ULID), the name is for display only and is the
/// name at the time, never looked up again. Nil wherever the server acted on its own or an agent
/// did, which is why every use of this is optional.
public struct AuthorRecord: Codable, Sendable, Hashable {
    public var userID: String
    public var name: String

    public init(userID: String, name: String) {
        self.userID = userID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case name
    }
}

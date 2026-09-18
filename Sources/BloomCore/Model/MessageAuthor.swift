import Foundation

/// The person who asked for a turn in a Cloud workspace, as runbloom.app named them.
///
/// Several people can prompt in one Cloud workspace, so a user row that says only "the owner"
/// is wrong about most of them. The id is runbloom.app's user id, the one its token carries in
/// `sub`, and the name is copied at the time rather than looked up again, so a row still says who
/// wrote it after that person has left the team.
///
/// Nil on every row a Mac writes for its own owner, which is every row outside a Cloud workspace:
/// on a Mac there is one person and nothing to tell apart.
public struct MessageAuthor: Sendable, Hashable, Codable {
    public var userID: String
    /// May be empty: not everybody has a display name. See `AuthorRecord.label` for what a client
    /// draws when it is.
    public var name: String
    /// Their address, when the token that carried them named one.
    public var email: String?

    public init(userID: String, name: String, email: String? = nil) {
        self.userID = userID
        self.name = name
        self.email = email
    }
}

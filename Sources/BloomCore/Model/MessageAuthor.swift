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
    public var name: String

    public init(userID: String, name: String) {
        self.userID = userID
        self.name = name
    }
}

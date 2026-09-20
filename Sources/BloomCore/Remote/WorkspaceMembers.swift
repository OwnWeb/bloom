import BloomProtocol
import Foundation

/// Somebody with access to this workspace, as runbloom.app lists them.
///
/// **A handle belongs to a membership rather than to a person**, because it has to be unique inside
/// one team and somebody in two teams may be `seb` in one and `sebdd` in the other. So this is only
/// ever read for the team this machine's workspace belongs to.
///
/// **No address.** A share-link guest is on this machine and completion is offered to whoever is
/// typing, so a directory of every member's email would be a way for somebody outside the team to
/// read the team's addresses by typing `@`. runbloom.app is told who was addressed by id and looks
/// the address up at its end, where it already lives. That is a different exposure from
/// `AuthorRecord.email`, which names the author of a message the reader can already see.
public struct WorkspaceMember: Sendable, Hashable, Codable {
    public var userID: String
    public var name: String
    /// What somebody types after `@`. Short, stable, and unique in this team.
    public var handle: String

    public init(userID: String, name: String, handle: String) {
        self.userID = userID
        self.name = name
        self.handle = handle
    }

    enum CodingKeys: String, CodingKey {
        case name, handle
        case userID = "user_id"
    }

    public var record: MemberRecord { MemberRecord(userID: userID, name: name, handle: handle) }

    /// What to draw for this person: their name, or their handle when the team has no name for
    /// them. **Never empty**, which is the whole reason it exists.
    public var label: String {
        let stated = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return stated.isEmpty ? handle : stated
    }
}

/// What the machine knows about one id it has been asked to address.
///
/// **Three answers, not two.** "Not a member" and "I have not been told who the members are" are
/// different, and collapsing them would either refuse a colleague who joined last week or accept an
/// id nobody has ever vouched for. The machine refuses both, and says which, because **addressing
/// the wrong person is the failure this whole feature exists to prevent**.
public enum MemberLookup: Sendable, Hashable {
    case member(WorkspaceMember)
    case notAMember
    /// runbloom.app has not told this machine who is in the team, or could not be reached to ask.
    case unknown
}

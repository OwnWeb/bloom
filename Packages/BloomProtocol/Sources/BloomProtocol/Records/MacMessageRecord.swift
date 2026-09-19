import Foundation

/// A message from an agent on this machine for a workspace on its person's Mac.
///
/// **Sent only down the event streams of the person whose turn is running.** A Mac cannot be
/// dialled; it can only be reached down a connection it opened, and this is that connection. The
/// machine picks the streams by the turn's person, as runbloom.app registered the turn, so a
/// colleague prompting the same workspace reaches their own Mac and never another's. See
/// "Bloom Cloud to a Mac" in docs/CLOUD-PARITY.md.
///
/// **The Mac checks it again and never treats it as typed words.** `user_id` has to be the person
/// signed in on that Mac, `workspace` has to name one of its own local workspaces, and the text
/// goes in as a message from elsewhere, in the untrusted envelope, headed with `via`.
public struct MacMessageRecord: Codable, Sendable, Hashable {
    /// Minted once per message, so a Mac with two streams open to this machine delivers it once.
    public var id: String
    /// The person whose Mac this is for: the running turn's person.
    public var userID: String
    /// A local workspace on that Mac, by the name the agent was given. The Mac resolves it and
    /// refuses a name it does not have.
    public var workspace: String
    public var text: String
    /// This workspace and chat, by name, so the Mac can say where it came from.
    public var via: ViaRecord

    public init(id: String, userID: String, workspace: String, text: String, via: ViaRecord) {
        self.id = id
        self.userID = userID
        self.workspace = workspace
        self.text = text
        self.via = via
    }

    enum CodingKeys: String, CodingKey {
        case id, workspace, text, via
        case userID = "user_id"
    }
}

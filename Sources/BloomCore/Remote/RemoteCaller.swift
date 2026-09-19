import Foundation

/// Who is asking the runtime for something, as the server established it from their token.
///
/// The runtime never sees a token's signature or lifetime; the server has checked those before
/// anything reaches here. What it needs is who to name as the author, what they may do, and the
/// token itself, because registering a turn with runbloom.app hands the prompter's own token on
/// at the moment they sent it. See `RemoteTurnGate`.
public struct RemoteCaller: Sendable, Hashable {
    /// Nil for the server acting on its own behalf, which only tests and setup do.
    public var author: MessageAuthor?
    public var abilities: Set<String>
    public var sessionToken: String?
    /// The workspace an agent was running in when its person's token was minted for it, read from
    /// the token's signed `act` claim. **A message on such a token is always labelled as an agent's**,
    /// whether or not the body says so: a label the sender can leave out is not a label.
    public var agentOrigin: String?

    public init(author: MessageAuthor?, abilities: Set<String>, sessionToken: String? = nil, agentOrigin: String? = nil) {
        self.author = author
        self.abilities = abilities
        self.sessionToken = sessionToken
        self.agentOrigin = agentOrigin
    }

    /// Every ability a person can hold, and no author: the runtime's own calls, and tests.
    public static let server = RemoteCaller(author: nil, abilities: ["view", "prompt", "terminal", "files", "preview", "share"])

    public func requires(_ ability: String) throws {
        guard abilities.contains("view"), abilities.contains(ability) else {
            throw RemoteFailure(.missingAbility, "Your access to this Bloom Cloud workspace does not include this.")
        }
    }
}

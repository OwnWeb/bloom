import BloomProtocol
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

    /// The ability `operation` needs, and for a token minted for an agent, whether it is one of the
    /// three that `workspace_say` sends.
    public func requires(_ operation: WorkspaceOperation) throws {
        if agentOrigin != nil, !Self.agentMayRun(operation) {
            throw RemoteFailure(.missingAbility, "A token minted for an agent in another workspace can only send a message here.")
        }
        try requires(operation.ability)
    }

    /// **What a token carrying `act` may do, whatever abilities it claims:** read the workspace to
    /// find a chat, open one, and send into it, which is all `RunbloomPeers.say` does. Everything
    /// else is refused, because the agent that caused the mint runs as a user that can read the
    /// workspace secret, and a token that could read files, set a chat's permission mode or answer
    /// a question would be that agent reaching into every workspace its person can open. The
    /// security review of 19 September 2026 found exactly that, as H1. Listed rather than derived
    /// from `ability`, so an operation added later is closed to agents until somebody opens it here.
    public static func agentMayRun(_ operation: WorkspaceOperation) -> Bool {
        switch operation {
        case .workspace, .newChat, .send: true
        default: false
        }
    }

    public func requires(_ ability: String) throws {
        guard abilities.contains("view"), abilities.contains(ability) else {
            throw RemoteFailure(.missingAbility, "Your access to this Bloom Cloud workspace does not include this.")
        }
    }
}

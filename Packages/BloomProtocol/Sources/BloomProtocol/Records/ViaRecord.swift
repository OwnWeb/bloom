import Foundation

/// That a message was written by an agent on somebody's behalf, and where that agent was.
///
/// **A message an agent sends through a person's token is the person's message**: the token is
/// theirs, the turn is theirs and so is the bill. Without this it would also read as words they
/// typed, which is how somebody finds themselves apparently asking for things they never asked for.
/// So the client that sent it says so, and every client draws it under the author.
///
/// **A label and nothing more.** It is written by the sending client and believed only for what it
/// says on screen: it grants nothing, changes nothing about who the author is, and is never given to
/// an agent as an instruction. Names rather than ids, because the only thing it is used for is
/// being read, and a local workspace's id means nothing on a machine.
public struct ViaRecord: Codable, Sendable, Hashable {
    /// `agent`, the only kind so far. The machine refuses any other rather than drawing a guess.
    public var kind: String
    /// The name of the workspace the agent was working in.
    public var workspace: String?
    /// The title of the chat it was running in.
    public var chat: String?

    public init(kind: String = ViaRecord.agent, workspace: String? = nil, chat: String? = nil) {
        self.kind = kind
        self.workspace = workspace
        self.chat = chat
    }

    public static let agent = "agent"
}

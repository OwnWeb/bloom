import Foundation

/// A quick prompt the project offers, read off the checkout on the machine by `quick_prompts`.
///
/// **Only the project's.** The owner's own quick prompts live in the database of whichever Bloom
/// they typed them into and are that client's to show; a machine has no owner and nothing of
/// anybody's own. What the machine has is the repository's settings file, which a client on the
/// other side of the network cannot read, so it answers for that and nothing else.
///
/// **It composes, it never sends.** These are words whoever last edited a committed file wrote,
/// and an agent with the run of the worktree reads them the moment they are sent. So there is no
/// `send_immediately` here: the machine refuses it on the way in and says so in `issues`, and a
/// client puts the words in the composer for a person to read and send.
///
/// **Asked for, not pushed.** The file is read again on every call, so a client asks when the
/// menu opens rather than once at connect, and an edit in the workspace, a pull or an agent
/// rewriting the file is in the next menu without an event for it.
public struct QuickPromptRecord: Codable, Sendable, Hashable {
    /// The name, trimmed and lowercased. Stable across reads, because it is derived rather than
    /// stored, and unique in one answer, because the machine refuses a second prompt with a name
    /// that folds to the same id.
    public var id: String
    public var name: String
    /// The words that go into the composer.
    public var prompt: String
    /// Always one Bloom can draw: an SF Symbol name from Bloom's own picker list, or one emoji. A
    /// symbol the file named that is not one of those arrives as the default, with an issue.
    public var symbol: String
    /// Whether choosing it opens a new chat for the words. A client that cannot open one composes
    /// in the chat on screen instead.
    public var isNewChat: Bool
    /// The settings file that stated it, relative to the worktree, such as `.bloom/settings.toml`.
    public var source: String

    public init(id: String, name: String, prompt: String, symbol: String, isNewChat: Bool, source: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.symbol = symbol
        self.isNewChat = isNewChat
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, symbol, source
        case isNewChat = "new_chat"
    }
}

/// Something wrong with the project's quick prompts, as a sentence a person can act on: a prompt
/// skipped because it has no name, one that will not send on its own, a settings file that would
/// not parse and so offered nothing.
public struct SettingsIssueRecord: Codable, Sendable, Hashable {
    /// The settings file, relative to the worktree.
    public var source: String
    public var message: String
    /// Where the entry starts, when the parser could say.
    public var line: Int?

    public init(source: String, message: String, line: Int? = nil) {
        self.source = source
        self.message = message
        self.line = line
    }
}

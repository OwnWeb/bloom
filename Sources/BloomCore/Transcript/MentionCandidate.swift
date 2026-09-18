import Foundation

/// A row in the mention menu: somebody on the team, or the thing that answers.
///
/// **The agent is a row because it is the commonest destination and was the one you could not
/// pick.** `@agent`, `@bloom` and the running agent's own name all resolve to it once the message
/// is sent, but a menu listing only people said "Nobody here is called blo" while somebody typed
/// `@bloom`, which reads as the feature being broken rather than as the agent being elsewhere.
///
/// **Whichever alias found it, picking it writes `@agent`.** The aliases exist so that typing what
/// comes to mind works, not so that four spellings of one destination end up in the transcripts a
/// team reads back. The web client took the same decision, which is why it is written here rather
/// than in either client's menu.
public enum MentionCandidate: Sendable, Hashable, Identifiable {
    /// The workspace's agent, labelled with what is actually answering.
    case agent(name: String)
    case person(ComposerAudience.Person)

    /// Stable across a filter, because a lazy stack serves the view it cached for a position while
    /// the list changes under an open menu. Prefixed, so a person who somehow held the handle
    /// `agent` could not collide with the agent's own row.
    public var id: String {
        switch self {
        case .agent: "agent:"
        case .person(let person): "person:" + person.id.rawValue
        }
    }

    /// What the reader is looking for, which is the name rather than the handle.
    public var name: String {
        switch self {
        case .agent(let name): name
        case .person(let person): person.name
        }
    }

    /// What is drawn beside the name, and for a person what they would have had to type.
    public var handle: String {
        switch self {
        case .agent: "agent"
        case .person(let person): person.handle
        }
    }

    /// What the completion writes, with the trailing space that separates it from the message.
    public var insertion: String { "@" + handle + " " }

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }
}

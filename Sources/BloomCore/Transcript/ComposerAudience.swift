import Foundation

/// Who the composer is addressed to, and who a person typing can name.
///
/// **The composer's half of `MessageAudience`, which is the message's.** The stored message keeps
/// an account id, because that is who it went to and a handle can change hands; the box somebody is
/// typing in needs the name and the handle as well, to say "You are writing to Seb" and to offer
/// him in a menu. Same fact, two shapes, and the id is what they agree on.
///
/// **A prompt has had one audience since Bloom existed, and it was never written down because
/// there was nothing else it could be.** In a shared Cloud workspace there is: `@seb` at the start
/// of a message says this one goes to Seb and not to the agent, and the agent must not see it at
/// all. So the audience becomes a thing a message carries, a composer remembers, and a bubble
/// says.
///
/// **The audience sticks.** Sending to a person leaves the composer addressed to that person, and
/// the next message with no `@` goes there too; `@agent` puts it back. The prefix changes the
/// audience rather than setting it for one message, which is the part of this feature that is
/// hardest to guess from a description and is exactly what a person means by "it remembers who I
/// was talking to".
public enum ComposerAudience: Equatable, Hashable, Sendable, Codable {
    /// The workspace's agent, which is every message Bloom has ever sent.
    case agent
    /// Somebody else who can open this workspace. The agent never sees it.
    case person(Person)

    /// Somebody a message can be addressed to, as the machine lists them: an account, a name and
    /// a handle.
    ///
    /// **The handle belongs to the membership rather than to the person, so it is resolved per
    /// workspace and never globally**: somebody in two teams may be `seb` in one and `sebdd` in
    /// the other, and a client that cached a handle against an account would address the wrong
    /// person in the second team.
    ///
    /// **No email, deliberately.** Completion is offered to whoever is typing, and somebody
    /// holding a share link is typing on the same machine, so a list carrying addresses would let
    /// a guest read the team's email by pressing `@`. Name and handle are what a menu needs.
    ///
    /// **And the stored mention is this id, not the word that was typed.** A handle given up and
    /// taken by somebody else would otherwise repoint every message ever addressed with it, and
    /// nothing would say so. The text keeps what was typed, which is what the bubble draws; who it
    /// went to is this.
    public struct Person: Equatable, Hashable, Sendable, Codable, Identifiable {
        public var id: CloudUserID
        public var handle: String
        public var name: String

        public init(id: CloudUserID, handle: String, name: String) {
            self.id = id
            self.handle = handle
            self.name = name
        }
    }

    public var person: Person? {
        guard case .person(let person) = self else { return nil }
        return person
    }

    public var isAgent: Bool { self == .agent }
}

/// What a handle may be, which is the control server's set and not this client's guess.
///
/// **A full stop is the one that matters, and the web client found it before either of us shipped
/// it: `@freek.spatie.be hello` is an email address at the start of a sentence, and a parser that
/// allowed a full stop would read it as a handle, fail to match it, and in a less careful
/// implementation address whoever `freek` turned out to be.** So the grammar is the gate: a run
/// after an `@` that is not a possible handle is not a mention at all, and an email at the start of
/// a message reads as what it is, which is words.
///
/// Lowercase letters, digits, hyphen and underscore, starting with a letter, two to thirty.
public enum MentionHandle {
    public static let minimumLength = 2
    public static let maximumLength = 30

    public static func isValid(_ handle: String) -> Bool {
        guard (minimumLength...maximumLength).contains(handle.count) else { return false }
        guard let first = handle.first, first.isLetter, first.isLowercase else { return false }
        return handle.allSatisfy { character in
            character.isLowercase && character.isLetter
                || character.isNumber && character.isASCII
                || character == "-" || character == "_"
        }
    }
}

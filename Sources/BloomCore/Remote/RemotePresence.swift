import BloomProtocol
import Foundation

/// Who has a Cloud workspace open, and when each of them last did something.
///
/// Two separate facts, because they answer two questions. An open stream says somebody is looking,
/// which is what a client draws as presence. Human input (a prompt, an answer, a keystroke, a
/// save) says somebody is working, which is what the presence lease that keeps the machine awake
/// counts from. A window left open over lunch is the first and not the second, and must not bill
/// for an hour. See docs/REMOTE-WORKSPACES.md, "Awake, asleep, and what it costs".
public struct RemotePresence: Sendable, Hashable {
    private var names: [String: String] = [:]
    private var lastInput: [String: Date] = [:]
    private(set) var connected: Set<String> = []

    public init() {}

    /// The most recent human input from anybody, which is what the lease runs from.
    public var lastHumanInputAt: Date? { lastInput.values.max() }

    /// **An empty name is not a name, and is never stored as one.** The name comes from whatever a
    /// token carried, and a person runbloom.app has no display name for carries an empty string.
    /// Kept as empty, it draws an empty chip, which is the same bug that let a colleague's message
    /// read as the reader's own: see `AuthorRecord.label`. Here the machine has somewhere better to
    /// look, so nothing is written rather than something blank, and `records(knownAs:)` fills it
    /// from the team.
    public mutating func noteInput(_ author: MessageAuthor, at date: Date) {
        note(author)
        lastInput[author.userID] = max(lastInput[author.userID] ?? date, date)
    }

    public mutating func noteName(_ author: MessageAuthor) {
        note(author)
    }

    private mutating func note(_ author: MessageAuthor) {
        let stated = author.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stated.isEmpty else { return }
        names[author.userID] = stated
    }

    /// Replaces the set of people with a stream open. Answers whether it changed.
    @discardableResult
    public mutating func setConnected(_ userIDs: Set<String>) -> Bool {
        guard userIDs != connected else { return false }
        connected = userIDs
        return true
    }

    /// Whether somebody has this workspace open right now, which is the fact only the machine
    /// holds and the one runbloom.app needs before it decides to send mail.
    public func isConnected(_ userID: String) -> Bool { connected.contains(userID) }

    public var records: [PresenceRecord] { records(knownAs: [:]) }

    /// Who is here, with the best name anybody has.
    ///
    /// **The token is not the only place a name lives.** The team list carries one for everybody,
    /// and a handle for everybody it has no name for, so a person whose token said nothing is still
    /// drawn as somebody rather than as a blank chip beside three named ones. Pass the members this
    /// machine knows; the map is `user_id` to what to draw.
    public func records(knownAs known: [String: String]) -> [PresenceRecord] {
        connected.sorted().map {
            PresenceRecord(userID: $0, name: names[$0] ?? known[$0] ?? "", lastInputAt: lastInput[$0])
        }
    }
}

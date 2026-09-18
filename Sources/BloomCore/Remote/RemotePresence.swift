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

    public mutating func noteInput(_ author: MessageAuthor, at date: Date) {
        names[author.userID] = author.name
        lastInput[author.userID] = max(lastInput[author.userID] ?? date, date)
    }

    public mutating func noteName(_ author: MessageAuthor) {
        names[author.userID] = author.name
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

    public var records: [PresenceRecord] {
        connected.sorted().map { PresenceRecord(userID: $0, name: names[$0] ?? "", lastInputAt: lastInput[$0]) }
    }
}

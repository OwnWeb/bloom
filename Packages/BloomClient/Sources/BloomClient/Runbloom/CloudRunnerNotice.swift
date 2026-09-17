import Foundation

/// What happened the last time a Cloud workspace's machine tried to update itself.
///
/// The machine updates on its own, and when a new version will not start it puts the previous one
/// back. That happened to somebody's workspace while they were not looking, and it should not be
/// silent: a workspace quietly running an older version than anybody thinks is exactly what
/// produces a bug report nobody can reproduce.
///
/// **The message is runbloom.app's, written as a finished sentence for a person, and is shown as it
/// stands.** `kind` decides how loudly and whether it can be put away, never what it says.
public struct CloudRunnerNotice: Codable, Sendable, Hashable {
    /// Being put back right now, which ends by itself and is replaced by one of the two below.
    public static let beingRolledBack = "update_being_rolled_back"
    /// It healed itself, on an older version than was intended.
    public static let rolledBack = "update_rolled_back"
    /// It did not heal, and somebody should look.
    public static let failed = "update_failed"

    public var kind: String
    public var message: String
    public var at: Date?

    public init(kind: String, message: String, at: Date? = nil) {
        self.kind = kind
        self.message = message
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case kind, message, at }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        at = try c.decodeIfPresent(RunbloomDate.self, forKey: .at)?.date
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(at.map(RunbloomDate.init), forKey: .at)
    }

    /// Whether this is something happening rather than something that has settled. A rollback in
    /// progress ends by itself and is replaced by its outcome, so nothing offers to hide it.
    public var isUnderway: Bool { kind == Self.beingRolledBack }
}

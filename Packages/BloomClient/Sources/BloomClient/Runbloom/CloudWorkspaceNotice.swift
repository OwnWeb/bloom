import Foundation

/// What runbloom.app currently needs to say about a Cloud workspace.
///
/// A notice can describe a Bloom Runner update or the workspace's own setup. Only one sits on a
/// workspace at a time. Provisional notices end by themselves and are replaced or removed, while
/// settled notices remain until somebody has seen them.
///
/// **The message is runbloom.app's, written as a finished sentence for a person, and is shown as it
/// stands.** `kind` decides how loudly and whether it can be put away, never what it says.
public struct CloudWorkspaceNotice: Codable, Sendable, Hashable {
    public static let beingRolledBack = "update_being_rolled_back"
    public static let rolledBack = "update_rolled_back"
    public static let updateFailed = "update_failed"
    public static let updateInterrupted = "update_interrupted"
    public static let setupRestarted = "setup_restarted"
    public static let setupNeverStarted = "setup_never_started"

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

    /// Whether this is something happening rather than something that has settled.
    public var isUnderway: Bool {
        kind == Self.beingRolledBack || kind == Self.setupRestarted
    }
}

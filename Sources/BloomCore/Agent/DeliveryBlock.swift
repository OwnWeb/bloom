import Foundation

/// A prompt runbloom.app would not start, and why.
///
/// A Cloud workspace asks runbloom.app for a key at the moment a turn starts, and runbloom.app
/// can refuse because a team limit was reached. The prompt stays queued, marked with this, and the
/// machine lets itself sleep rather than poll, because polling would keep it awake and billing,
/// which is exactly what the limit is for. It is tried again when runbloom.app says the limit
/// lifted, or when the machine wakes for anything else.
///
/// `limit` is runbloom.app's word (`monthly_usage`, `concurrent_machines`, `total_machines`,
/// `kill_switch`) and `message` is its sentence, shown as written.
public struct DeliveryBlock: Sendable, Hashable, Codable {
    public var limit: String
    public var message: String

    public init(limit: String, message: String) {
        self.limit = limit
        self.message = message
    }

    /// Whether this one clears on its own when another machine in the team goes to sleep, which
    /// is the one a client shows as waiting rather than blocked.
    public var clearsByItself: Bool { limit == "concurrent_machines" }
}

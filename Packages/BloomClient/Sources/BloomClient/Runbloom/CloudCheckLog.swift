import Foundation

/// A failed check's log as runbloom.app reads it for a Bloom Cloud workspace: the first 40 and
/// last 160 lines of the failed steps, with the markers `CheckFailureHandoff` uses, capped at
/// 24,000 characters. Nil `log` comes with a sentence saying why there is none, and the check is
/// still worth handing over by its name and URL.
public struct CloudCheckLog: Decodable, Sendable, Hashable {
    public struct Log: Decodable, Sendable, Hashable {
        public var text: String
        public var filename: String
        public var totalLines: Int
        public var droppedLines: Int
        public var truncated: Bool

        enum CodingKeys: String, CodingKey {
            case text, filename, truncated
            case totalLines = "total_lines"
            case droppedLines = "dropped_lines"
        }
    }

    public var log: Log?
    public var unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case log
        case unavailableReason = "log_unavailable_reason"
    }
}

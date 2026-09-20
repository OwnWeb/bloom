import Foundation

/// One transcript row a search matched, in the shape Bloom's own search panel draws.
///
/// The excerpt keeps the pieces that matched marked, because the panel highlights them and the
/// machine already knows which they are: SQLite's own FTS5 snippet says so, and working it out
/// again on a Mac would mean sending whole messages there to find out.
public struct SearchMatchRecord: Codable, Sendable, Hashable {
    public struct Piece: Codable, Sendable, Hashable {
        public var text: String
        public var isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }

        enum CodingKeys: String, CodingKey {
            case text
            case isMatch = "is_match"
        }
    }

    public var chatID: String
    public var chatTitle: String
    public var seq: Int
    /// The transcript row's id, the same cursor an event carries, so a client can open the row.
    public var cursor: Int64
    public var kind: String
    public var at: Date
    public var excerpt: [Piece]

    public init(chatID: String, chatTitle: String, seq: Int, cursor: Int64, kind: String, at: Date, excerpt: [Piece]) {
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.seq = seq
        self.cursor = cursor
        self.kind = kind
        self.at = at
        self.excerpt = excerpt
    }

    enum CodingKeys: String, CodingKey {
        case seq, cursor, kind, at, excerpt
        case chatID = "chat_id"
        case chatTitle = "chat_title"
    }
}

/// What a search answers: the best matches, and how many there are in all.
public struct SearchRecord: Codable, Sendable, Hashable {
    public var matches: [SearchMatchRecord]
    public var total: Int

    public init(matches: [SearchMatchRecord], total: Int) {
        self.matches = matches
        self.total = total
    }
}

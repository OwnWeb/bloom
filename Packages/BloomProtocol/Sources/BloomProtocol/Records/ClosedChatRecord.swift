import Foundation

/// One row in a workspace's bounded Recently Closed list.
///
/// This is deliberately smaller than `ChatRecord`. A closed chat cannot be composed into, and a
/// client only needs enough to identify it, distinguish similarly named rows and ask to reopen it.
/// A successful `reopen_chat` answers with the full ordinary `ChatRecord`.
public struct ClosedChatRecord: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var agent: String
    public var messageCount: Int
    public var closedAt: Date

    public init(id: String, title: String, agent: String, messageCount: Int, closedAt: Date) {
        self.id = id
        self.title = title
        self.agent = agent
        self.messageCount = messageCount
        self.closedAt = closedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, agent
        case messageCount = "message_count"
        case closedAt = "closed_at"
    }
}

import Foundation

/// Keeps a Cloud echo's identity after a queue acknowledgement replaces its drawing. The saved
/// row can arrive in a later snapshot, after `sending` has gone away.
public struct SentMessageHandoff: Sendable {
    private var pending: (id: DeliveryID, body: String)?

    public init() {}

    public mutating func hold(_ delivery: Delivery) {
        pending = (delivery.id, delivery.body)
    }

    public mutating func take(for message: Message, readerID: String?) -> DeliveryID? {
        guard let pending, Self.matches(message, body: pending.body, readerID: readerID) else { return nil }
        self.pending = nil
        return pending.id
    }

    public mutating func discard(_ id: DeliveryID) {
        if pending?.id == id { pending = nil }
    }

    public static func matches(_ message: Message, body: String, readerID: String?) -> Bool {
        message.kind == .user
            && !MessageAuthorship.isFromSomebodyElse(author: message.author?.userID, reader: readerID)
            && UserTurnPrompt.text(in: message.payload) == body
    }
}

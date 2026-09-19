import BloomProtocol
import Foundation

/// That an agent wrote a message on its author's behalf, and where it was. A label for the window
/// and nothing else: it grants nothing and is never handed to an agent. See `ViaRecord`.
public struct MessageVia: Codable, Sendable, Hashable {
    public var workspace: String?
    public var chat: String?

    public init(workspace: String? = nil, chat: String? = nil) {
        self.workspace = workspace
        self.chat = chat
    }

    /// Longer than any workspace name or chat title Bloom writes, short enough that a label cannot
    /// carry a paragraph into somebody else's transcript.
    static let limit = 200

    /// Refused at the edge rather than guessed at: a kind this machine does not know is a client
    /// saying something it cannot draw.
    public init(record: ViaRecord) throws {
        guard record.kind == ViaRecord.agent else {
            throw RemoteFailure.invalid("A message can say an agent sent it, and nothing else.")
        }
        func label(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : String(trimmed.prefix(Self.limit))
        }
        self.init(workspace: label(record.workspace), chat: label(record.chat))
    }

    public var record: ViaRecord { ViaRecord(workspace: workspace, chat: chat) }

    /// Stored as one JSON column, because it is read whole and never queried by.
    var column: String? {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func from(column text: String?) -> MessageVia? {
        text.flatMap { try? JSONDecoder().decode(MessageVia.self, from: Data($0.utf8)) }
    }
}

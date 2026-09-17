import Foundation

/// One call to `POST /_bloom/v1/rpc`.
///
/// **The command id is the client's, and it is kept.** A client that did not see a reply sends
/// the same id again, and the server answers a mutation it already ran with the reply it recorded
/// the first time rather than running it twice. That is the whole of what makes a retry after a
/// dropped connection or a machine that paused mid-request safe, and why a client must never mint
/// a new id to retry: see the client chapter of docs/WORKSPACE-PROTOCOL.md.
public struct CommandRequest: Codable, Sendable, Hashable {
    public var `protocol`: String
    public var version: Int
    public var commandID: String
    public var operation: WorkspaceOperation

    public init(_ operation: WorkspaceOperation, commandID: String = UUID().uuidString.lowercased()) {
        self.protocol = WorkspaceProtocol.name
        self.version = WorkspaceProtocol.version
        self.commandID = commandID
        self.operation = operation
    }

    enum CodingKeys: String, CodingKey {
        case `protocol`, version, operation
        case commandID = "command_id"
    }
}

/// The answer to one command: a result or an error, never both.
public struct CommandReply: Codable, Sendable, Hashable {
    public var version: Int
    public var commandID: String
    public var result: OperationResult?
    public var error: WireError?

    public init(commandID: String, result: OperationResult) {
        version = WorkspaceProtocol.version
        self.commandID = commandID
        self.result = result
        error = nil
    }

    public init(commandID: String, error: WireError) {
        version = WorkspaceProtocol.version
        self.commandID = commandID
        result = nil
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case version, result, error
        case commandID = "command_id"
    }
}

/// How a tagged value is laid out: one object with a `kind`, and the value's fields beside it.
///
/// A case carrying a whole record puts that record under a key named after the kind, as in
/// `{"kind": "transcript", "transcript": {...}}`, rather than spreading its fields beside `kind`.
/// Spreading them was tried first and a transcript row's own `kind` field overwrote the tag.
enum Tagged {
    enum KindKey: String, CodingKey { case kind }

    struct NamedKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func kind(from decoder: any Decoder) throws -> String {
        try decoder.container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
    }

    static func encode(kind: String, to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: KindKey.self)
        try container.encode(kind, forKey: .kind)
    }

    /// The record a case carries, under a key named after its kind.
    static func encode(kind: String, to encoder: any Encoder, record: some Encodable) throws {
        try encode(kind: kind, to: encoder)
        var container = encoder.container(keyedBy: NamedKey.self)
        try container.encode(record, forKey: NamedKey(kind))
    }

    static func record<Value: Decodable>(_ type: Value.Type, kind: String, from decoder: any Decoder) throws -> Value {
        try decoder.container(keyedBy: NamedKey.self).decode(type, forKey: NamedKey(kind))
    }

    static func unknown(_ kind: String, in decoder: any Decoder) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown kind \(kind)"))
    }
}

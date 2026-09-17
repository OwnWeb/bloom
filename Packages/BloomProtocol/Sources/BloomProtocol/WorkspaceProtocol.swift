import Foundation

/// The name and version every envelope carries.
///
/// **Version 1 is a fresh start, not the seventeenth version of #163's protocol.** That one
/// negotiated between 12 and 16 because it had clients in the field; this one has none, so it
/// carries no negotiation and refuses anything that is not exactly its own version. A later
/// version that has to coexist with this one adds negotiation then, when there is something to
/// negotiate with.
public enum WorkspaceProtocol {
    public static let name = "bloom-workspace"
    public static let version = 1
}

/// The JSON coders every reader and writer of these shapes uses.
///
/// Dates are ISO 8601 with fractional seconds, because Foundation's default counts seconds from
/// 2001 and a reader in any other language would have to know that. Everything else is spelled
/// out by each type's own coding keys, so nothing here depends on a key strategy that a client
/// holding its own `JSONEncoder` could forget to set.
public enum WireJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(WireDate.string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = WireDate.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date, found \(text)")
            }
            return date
        }
        return decoder
    }

    public static func encode(_ value: some Encodable) throws -> Data { try encoder().encode(value) }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try decoder().decode(type, from: data)
    }
}

/// ISO 8601 in UTC, with milliseconds.
///
/// Parsing accepts whole seconds as well, because runbloom.app writes those and both are the same
/// instant to a reader. A formatter per call rather than a shared one, because
/// `ISO8601DateFormatter` is not `Sendable` and these are not on any path hot enough to notice.
public enum WireDate {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

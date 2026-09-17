import Foundation

/// Arbitrary JSON, for the few fields that carry an agent's own shapes through unchanged: a
/// transcript row's payload, a question's request, a question's answer.
///
/// Not called `JSONValue`, because BloomCore has one and imports this module, and two types of
/// that name in one file is an ambiguity at every use.
public enum WireValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WireValue])
    case object([String: WireValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WireValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: WireValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers go out without a decimal point, so an id or a count reads as one.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses raw JSON bytes, or nil for bytes that are not JSON.
    public static func parse(_ data: Data) -> WireValue? {
        try? JSONDecoder().decode(WireValue.self, from: data)
    }

    /// The compact bytes, for handing back to code that wants the agent's JSON as it was.
    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}

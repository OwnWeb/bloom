import BloomCore
import Foundation

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let keys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
    guard Set(keys) == expected else { throw MachineEnvironmentContractError("The response shape is not version 1.") }
}

private func requireVersion(_ version: Int) throws {
    guard version == 1 else { throw MachineEnvironmentContractError("The response version is not supported.") }
}

private func validEnvironment(_ values: [String: String]) throws {
    guard values.keys.allSatisfy(EnvironmentName.isValid) else {
        throw MachineEnvironmentContractError("A variable name is not a POSIX environment name.")
    }
}

private enum EnvironmentName {
    static func isValid(_ name: String) -> Bool {
        guard let first = name.utf8.first, !(48...57).contains(first) else { return false }
        return !name.isEmpty && name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
        }
    }
}

public struct MachineEnvironmentResponse: Sendable, Equatable, Decodable {
    public let variables: [String: String]

    public init(variables: [String: String]) throws {
        try validEnvironment(variables)
        self.variables = variables
    }

    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["version", "variables"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireVersion(container.decode(Int.self, forKey: .version))
        let variables = try container.decode([String: String].self, forKey: .variables)
        try self.init(variables: variables)
    }

    private enum CodingKeys: String, CodingKey { case version, variables }
}

public enum SecretHandoffScope: Sendable, Equatable {
    case setup(attemptID: UUID)
    case service(id: String, launchID: UUID)

    var issueBody: Data {
        get throws {
            let value: [String: Any]
            switch self {
            case .setup(let attemptID):
                value = ["version": 1, "kind": "setup", "attempt_id": attemptID.uuidString.lowercased()]
            case .service(let id, let launchID):
                guard RemoteProjectSettings.validServiceID(id) else {
                    throw MachineEnvironmentContractError("The service id is invalid.")
                }
                value = ["version": 1, "kind": "service", "service_id": id,
                         "launch_id": launchID.uuidString.lowercased()]
            }
            return try JSONSerialization.data(withJSONObject: value)
        }
    }
}

public struct SecretHandoff: Sendable, Equatable, Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    public let expiresAt: Date

    public init(id: String, expiresAt: Date) throws {
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
        guard id.count == 26, id.utf8.allSatisfy(alphabet.contains) else {
            throw MachineEnvironmentContractError("The handoff id is not a ULID.")
        }
        self.id = id
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["version", "handoff_id", "expires_at"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireVersion(container.decode(Int.self, forKey: .version))
        let id = try container.decode(String.self, forKey: .id)
        let text = try container.decode(String.self, forKey: .expiresAt)
        guard text.hasSuffix("Z"), let date = Self.date(text) else {
            throw MachineEnvironmentContractError("The handoff expiry is invalid.")
        }
        try self.init(id: id, expiresAt: date)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id = "handoff_id"
        case expiresAt = "expires_at"
    }
    private static func date(_ text: String) -> Date? {
        let format = Date.ISO8601FormatStyle()
        guard let dot = text.firstIndex(of: ".") else { return try? format.parse(text) }
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let whole = String(text[..<dot]) + String(text[digits.endIndex...])
        guard let seconds = try? format.parse(whole) else { return nil }
        return seconds.addingTimeInterval(Double("0." + digits) ?? 0)
    }
    public var description: String { "SecretHandoff(expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

public struct SecretHandoffConsumption: Sendable, Equatable, Decodable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let secrets: [String: String]

    public init(secrets: [String: String]) throws {
        try validEnvironment(secrets)
        guard secrets.values.allSatisfy({ !$0.isEmpty }) else {
            throw MachineEnvironmentContractError("A secret value is empty.")
        }
        self.secrets = secrets
    }

    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["version", "secrets"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireVersion(container.decode(Int.self, forKey: .version))
        try self.init(secrets: container.decode([String: String].self, forKey: .secrets))
    }

    private enum CodingKeys: String, CodingKey { case version, secrets }
    public var description: String { "SecretHandoffConsumption(names: [\(secrets.keys.sorted().joined(separator: ", "))])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

public struct ScopedProcessEnvironment: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var values: [String: String]
    public var redactions: [String]
    public init(values: [String: String], redactions: [String]) { self.values = values; self.redactions = redactions }
    public var description: String {
        "ScopedProcessEnvironment(names: [\(values.keys.sorted().joined(separator: ", "))], redactions: \(redactions.count))"
    }
    public var debugDescription: String { description }
}

struct MachineEnvironmentContractError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

import BloomCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import NIOHTTP1

public struct MachineIdentityDescriptor: Codable, Sendable, Hashable {
    public var publicKey: String
    public var keyID: MachineIdentityKeyID

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case keyID = "key_id"
    }
}

struct MachineIdentityProofHeaders: Sendable, Hashable {
    var version = "1"
    var keyID: MachineIdentityKeyID
    var timestamp: Int64
    var requestID: String
    var signature: String

    var fields: [String: String] {
        [
            "X-Bloom-Proof-Version": version,
            "X-Bloom-Proof-Key-Id": keyID.rawValue,
            "X-Bloom-Proof-Timestamp": String(timestamp),
            "X-Bloom-Proof-Request-Id": requestID,
            "X-Bloom-Proof-Signature": signature,
        ]
    }
}

struct MachineIdentityRegistration: Sendable, Hashable {
    var timestamp: Int64
    var requestID: String
    var publicKey: String
    var signature: String

    var body: Data {
        Data("{\"public_key\":\"\(publicKey)\",\"signature\":\"\(signature)\"}".utf8)
    }
}

struct MachineIdentityRequestBinding: Sendable {
    var method: HTTPMethod
    var target: String
    var machineID: CloudMachineID
    var workspaceID: WorkspaceID
    var timestamp: Int64
    var requestID: UUID
    var body: Data
}

enum MachineIdentityKeyOperation: String, Sendable {
    case register
    case rotate
}

struct MachineIdentityKeyBinding: Sendable {
    var operation: MachineIdentityKeyOperation
    var method: HTTPMethod
    var target: String
    var machineID: CloudMachineID
    var workspaceID: WorkspaceID
    var timestamp: Int64
    var requestID: UUID
    var publicKey: String
    var previousKeyID: MachineIdentityKeyID?
}

enum MachineIdentityCanonical {
    static func request(_ binding: MachineIdentityRequestBinding) -> Data {
        let hash = SHA256.hash(data: binding.body).map { String(format: "%02x", $0) }.joined()
        return Data((
            "{\"version\":\"1\",\"operation\":\"request\",\"method\":\(quoted(binding.method.rawValue.uppercased())),"
                + "\"target\":\(quoted(binding.target)),\"machine_id\":\(quoted(binding.machineID.rawValue)),"
                + "\"workspace_id\":\(quoted(binding.workspaceID.rawValue)),\"issued_at\":\(binding.timestamp),"
                + "\"request_id\":\(quoted(binding.requestID.uuidString.lowercased())),\"content_sha256\":\(quoted(hash))}"
        ).utf8)
    }

    static func registration(_ binding: MachineIdentityKeyBinding) -> Data {
        let previous = binding.previousKeyID.map { quoted($0.rawValue) } ?? "null"
        return Data((
            "{\"version\":\"1\",\"operation\":\(quoted(binding.operation.rawValue)),"
                + "\"method\":\(quoted(binding.method.rawValue.uppercased())),\"target\":\(quoted(binding.target)),"
                + "\"machine_id\":\(quoted(binding.machineID.rawValue)),\"workspace_id\":\(quoted(binding.workspaceID.rawValue)),"
                + "\"issued_at\":\(binding.timestamp),\"request_id\":\(quoted(binding.requestID.uuidString.lowercased())),"
                + "\"public_key\":\(quoted(binding.publicKey)),\"previous_key_id\":\(previous)}"
        ).utf8)
    }

    /// JSON string escaping written here because key order, whitespace and unescaped slashes are
    /// protocol bytes. A general-purpose encoder is allowed to change all three.
    private static func quoted(_ value: String) -> String {
        var answer = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: answer += "\\\""
            case 0x5c: answer += "\\\\"
            case 0x08: answer += "\\b"
            case 0x0c: answer += "\\f"
            case 0x0a: answer += "\\n"
            case 0x0d: answer += "\\r"
            case 0x09: answer += "\\t"
            case 0x00...0x1f: answer += String(format: "\\u%04x", scalar.value)
            default: answer.unicodeScalars.append(scalar)
            }
        }
        return answer + "\""
    }
}

struct MachineIdentityResponse: Decodable {
    var version: Int
    var keyID: MachineIdentityKeyID

    enum CodingKeys: String, CodingKey {
        case version
        case keyID = "key_id"
    }
}

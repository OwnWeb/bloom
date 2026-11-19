import Foundation

/// The wire layer of the Agent Client Protocol: JSON-RPC 2.0, one message per line over stdio.
///
/// Shared by every backend that speaks ACP (`grok agent stdio`, `opencode acp`). Only the framing
/// lives here. How a process is launched, how a model is chosen and how a permission is decided
/// are each backend's own, which is why there is no shared runner.
///
/// Frame classification is the JSON-RPC one, never by id: `method` plus `id` is a request,
/// `method` alone a notification, `result` or `error` a response. The client's request ids and the
/// server's own can share numbers, so a frame is never typed by looking at its id.
public enum ACPRequestID: Sendable, Hashable, Codable {
    case number(Int)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    var jsonLiteral: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): JSONValue.string(value).compactJSON
        }
    }

    /// The turn handle's id for this request. Distinct from the ACP session id, which is stable
    /// across turns and must not be reused as a turn id.
    var turnID: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): value
        }
    }

    init?(_ json: JSONValue?) {
        switch json {
        case .integer(let value): self = .number(value)
        case .string(let value): self = .text(value)
        default: return nil
        }
    }
}

public struct ACPRPCError: Sendable, Hashable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum ACPClientError: Sendable, Error, Equatable {
    case connectionClosed(String)
    case unexpectedResult(method: String)
    case notInitialized
    case timedOut(method: String, seconds: Int)
}

public struct ACPServerRequest: Sendable, Hashable {
    public let id: ACPRequestID
    public let method: String
    public let params: JSONValue
    public let raw: Data

    public init(id: ACPRequestID, method: String, params: JSONValue, raw: Data = Data()) {
        self.id = id
        self.method = method
        self.params = params
        self.raw = raw
    }
}

public struct ACPServerNotification: Sendable, Hashable {
    public let method: String
    public let params: JSONValue
    public let raw: Data

    public init(method: String, params: JSONValue, raw: Data = Data()) {
        self.method = method
        self.params = params
        self.raw = raw
    }
}

/// One decoded line off the agent.
///
/// Nothing here throws. A line that is not JSON comes back as `.malformed` with its bytes intact,
/// because the agent writes tracing to stderr and a future release could write something new to
/// stdout, and neither may end a session.
public enum ACPFrame: Sendable, Hashable {
    case response(id: ACPRequestID, result: JSONValue, raw: Data)
    case failure(id: ACPRequestID, error: ACPRPCError, raw: Data)
    case request(ACPServerRequest)
    case notification(ACPServerNotification)
    case malformed(Data)

    public static func decode(line: String) -> ACPFrame? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let raw = Data(line.utf8)
        guard let json = JSONValue.parse(raw), case .object = json else { return .malformed(raw) }

        let id = ACPRequestID(json["id"])
        let params = json["params"] ?? .object([:])

        if let method = json["method"]?.stringValue {
            if let id {
                return .request(ACPServerRequest(id: id, method: method, params: params, raw: raw))
            }
            return .notification(ACPServerNotification(method: method, params: params, raw: raw))
        }

        guard let id else { return .malformed(raw) }

        if let error = json["error"] {
            return .failure(
                id: id,
                error: ACPRPCError(
                    code: error["code"]?.intValue ?? 0,
                    message: error["message"]?.stringValue ?? "",
                    data: error["data"]
                ),
                raw: raw
            )
        }

        guard case .object(let object) = json, object.keys.contains("result") else {
            return .malformed(raw)
        }
        return .response(id: id, result: object["result"] ?? .null, raw: raw)
    }
}

public enum ACPOutgoing {
    static let version = "2.0"

    public static func request(id: ACPRequestID, method: String, params: JSONValue?) -> String {
        var members = ["\"jsonrpc\":\"\(version)\"", "\"id\":\(id.jsonLiteral)"]
        members.append("\"method\":\(JSONValue.string(method).compactJSON)")
        if let params { members.append("\"params\":\(params.compactJSON)") }
        return "{" + members.joined(separator: ",") + "}"
    }

    public static func notification(method: String, params: JSONValue?) -> String {
        var members = ["\"jsonrpc\":\"\(version)\""]
        members.append("\"method\":\(JSONValue.string(method).compactJSON)")
        if let params { members.append("\"params\":\(params.compactJSON)") }
        return "{" + members.joined(separator: ",") + "}"
    }

    public static func response(id: ACPRequestID, result: JSONValue) -> String {
        "{\"jsonrpc\":\"\(version)\",\"id\":\(id.jsonLiteral),\"result\":\(result.compactJSON)}"
    }

    public static func failure(id: ACPRequestID, code: Int, message: String) -> String {
        let error = JSONValue.object([
            "code": .integer(code),
            "message": .string(message),
        ])
        return "{\"jsonrpc\":\"\(version)\",\"id\":\(id.jsonLiteral),\"error\":\(error.compactJSON)}"
    }
}

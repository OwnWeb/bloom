import Foundation

/// One ACP event Bloom cares about, decoded from `grok agent stdio`.
///
/// Most of what the agent sends is noise for a transcript: MCP handshake progress, announcement
/// banners, settings dumps. Those land in `.unknown` with the method name intact and stop there.
/// `AgentEvent.unknown` is a stored row, so forwarding them would fill the chat with lines
/// nobody can read.
public enum GrokEvent: Sendable, Hashable {
    case sessionReady(GrokSession)
    case update(GrokSessionUpdate)
    case permission(GrokPermissionRequest)
    case promptCompleted(GrokPromptResult)
    case closed(reason: String)
    case unknown(method: String, raw: Data)

    public var sessionID: String? {
        switch self {
        case .sessionReady(let session): session.id
        case .update(let update): update.sessionID
        case .permission(let request): request.sessionID
        case .promptCompleted(let result): result.sessionID
        case .closed, .unknown: nil
        }
    }
}

public struct GrokSession: Sendable, Hashable {
    public let id: String
    public let models: [GrokModel]
    public let currentModelID: String
    public let raw: Data

    public init(id: String, models: [GrokModel] = [], currentModelID: String = "", raw: Data = Data()) {
        self.id = id
        self.models = models
        self.currentModelID = currentModelID
        self.raw = raw
    }

    public static func decode(_ json: JSONValue, raw: Data = Data()) -> GrokSession? {
        guard let id = json["sessionId"]?.stringValue, !id.isEmpty else { return nil }
        let modelsJSON = json["models"] ?? json["_meta"]?["modelState"] ?? .null
        return GrokSession(
            id: id,
            models: GrokModel.decodeList(modelsJSON),
            currentModelID: modelsJSON["currentModelId"]?.stringValue ?? "",
            raw: raw
        )
    }
}

public typealias GrokSessionUpdate = ACPSessionUpdate
public typealias GrokToolCall = ACPToolCall
public typealias GrokPromptResult = ACPPromptResult
public typealias GrokPermissionOption = ACPPermissionOption
public typealias GrokPermissionRequest = ACPPermissionRequest

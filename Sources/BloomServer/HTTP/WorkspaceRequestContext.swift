import Hummingbird
import HummingbirdWebSocket

/// The request context every route on the machine gets: Hummingbird's own, plus the handle the
/// terminal route uses to upgrade to a WebSocket.
public struct WorkspaceRequestContext: RequestContext, WebSocketRequestContext {
    public var coreContext: CoreRequestContextStorage
    public let webSocket: WebSocketHandlerReference<Self>

    public init(source: Source) {
        coreContext = .init(source: source)
        webSocket = .init()
    }

    /// Uploads are 8 MB, which is a little under 11 MB as base64 inside a JSON envelope.
    public var maxUploadSize: Int { 12 * 1_024 * 1_024 }
}

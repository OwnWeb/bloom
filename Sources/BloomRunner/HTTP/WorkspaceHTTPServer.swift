import BloomCore
import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket

/// Everything Bloom Runner answers on its port, behind Caddy.
///
/// | Path | What |
/// | --- | --- |
/// | `POST /_bloom/v1/rpc` | a command, session token |
/// | `GET /_bloom/v1/events` | server-sent events, session token |
/// | `POST /_bloom/v1/streams/{id}/token` | a fresh token for an open stream |
/// | `GET /_bloom/v1/terminal?name=` | WebSocket, `auth` first frame |
/// | `GET /_bloom/preview/enter?token=` | the preview cookie exchange, preview token |
/// | `GET /_bloom/preview/check` | Caddy's forward_auth for the preview |
/// | `POST /_bloom/v1/control/*` | runbloom.app only, control token |
/// | `GET /_bloom/health` | unauthenticated, the version only |
/// | `POST /_bloom/local/git-credentials` | loopback only, never routed by Caddy |
public struct WorkspaceHTTPServer: Sendable {
    public struct Dependencies: Sendable {
        public var runtime: WorkspaceRuntime
        public var verifier: TokenVerifier
        public var gate: any RemoteTurnGate
        public var control: any MachineControl
        public var store: Store
        public var allowedOrigins: [String]
        public var version: String
        public var streams: EventStreams
        public var terminals: TerminalConnections
        /// The loopback route git's credential helper asks, when there is one.
        public var gitCredentials: GitCredentials?

        public init(runtime: WorkspaceRuntime, verifier: TokenVerifier, gate: any RemoteTurnGate, control: any MachineControl,
                    store: Store, allowedOrigins: [String], version: String, streams: EventStreams = EventStreams(),
                    terminals: TerminalConnections = TerminalConnections(), gitCredentials: GitCredentials? = nil) {
            self.runtime = runtime
            self.verifier = verifier
            self.gate = gate
            self.control = control
            self.store = store
            self.allowedOrigins = allowedOrigins
            self.version = version
            self.streams = streams
            self.terminals = terminals
            self.gitCredentials = gitCredentials
        }
    }

    public struct GitCredentials: Sendable {
        public var secret: String
        public var repository: String
        public var fetch: @Sendable (String, RunbloomGitOperation, String?) async throws -> RunbloomGitCredential

        public init(secret: String, repository: String, fetch: @escaping @Sendable (String, RunbloomGitOperation, String?) async throws -> RunbloomGitCredential) {
            self.secret = secret
            self.repository = repository
            self.fetch = fetch
        }
    }

    public var streams: EventStreams { dependencies.streams }
    public var terminals: TerminalConnections { dependencies.terminals }
    let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func router() -> Router<WorkspaceRequestContext> {
        let router = Router(context: WorkspaceRequestContext.self)
        let version = dependencies.version
        router.get("/_bloom/health") { _, _ -> Response in
            WireResponses.json(["version": version])
        }
        RPCRoute.register(on: router, runtime: dependencies.runtime, verifier: dependencies.verifier)
        EventStreamRoute.register(on: router, runtime: dependencies.runtime, verifier: dependencies.verifier, streams: streams)
        ControlRoutes.register(on: router, verifier: dependencies.verifier, control: dependencies.control)
        PreviewRoutes.register(on: router, verifier: dependencies.verifier, sessions: PreviewSessions(store: dependencies.store, revocations: dependencies.verifier.revocations),
                               runtime: dependencies.runtime)
        if let credentials = dependencies.gitCredentials {
            GitCredentialRoute.register(on: router, secret: credentials.secret, repository: credentials.repository,
                                        runtime: dependencies.runtime, fetch: credentials.fetch)
        }
        return router
    }

    func webSocketRouter() -> Router<WorkspaceRequestContext> {
        let router = Router(context: WorkspaceRequestContext.self)
        TerminalRoute.register(on: router, dependencies: .init(runtime: dependencies.runtime, verifier: dependencies.verifier,
                                                               gate: dependencies.gate, connections: terminals))
        return router
    }

    /// The application, listening on loopback only: Caddy is the one thing on the machine's URL.
    public func application(port: Int, host: String = "127.0.0.1",
                            onServerRunning: @escaping @Sendable (Int) async -> Void = { _ in }) -> some ApplicationProtocol {
        let responder = CORSResponder(wrapped: router().buildResponder(), allowedOrigins: Set(dependencies.allowedOrigins))
        return Application(
            responder: responder,
            server: .http1WebSocketUpgrade(webSocketRouter: webSocketRouter()),
            configuration: .init(address: .hostname(host, port: port), serverName: "bloom-runner"),
            onServerRunning: { channel in await onServerRunning(channel.localAddress?.port ?? port) }
        )
    }
}

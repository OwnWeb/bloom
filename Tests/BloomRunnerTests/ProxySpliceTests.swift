import BloomProtocol
import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import HummingbirdWSTesting
import NIOCore
import NIOPosix
import NIOWebSocket
import Testing
@testable import BloomCore
@testable import BloomRunner

/// The proxy route with a real TCP service behind it and a real WebSocket in front.
///
/// `ProxyRouteTests` holds the decisions taken before a byte moves. This holds what happens after:
/// that bytes cross in both directions and come back whole, that every refusal reaches the client
/// as the close code it acts on, and that a forward ends when its person's access does. The service
/// is an echo listener on loopback, which is all a database is to this route.
@Suite("A forward, end to end")
struct ProxySpliceTests {
    let issuer = TestTokenIssuer()
    let clock = TestClock()

    /// The route alone, on a live server, as `WorkspaceHTTPServer` mounts it.
    func application(
        connections: TerminalConnections = TerminalConnections(), reserved: [Int] = [], hosts: [String] = ["127.0.0.1", "::1"],
        clock: TestClock? = nil
    ) -> some ApplicationProtocol {
        let router = Router(context: WorkspaceRequestContext.self)
        ProxyRoute.register(on: router, dependencies: .init(
            verifier: issuer.verifier(clock: clock ?? self.clock), connections: connections, reservedPorts: reserved, hosts: hosts
        ))
        return Application(
            router: Router(context: WorkspaceRequestContext.self),
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
    }

    static func auth(_ token: String) -> String {
        String(decoding: try! WireJSON.encode(TerminalControlFrame.auth(token: token)), as: UTF8.self)
    }

    /// Everything the machine sends until it closes, and how it closed.
    static func refusal(
        _ client: some TestClientProtocol, port: Int, token: String
    ) async throws -> WebSocketCloseFrame? {
        try await client.ws("/_bloom/v1/proxy?port=\(port)") { inbound, outbound, _ in
            try await outbound.write(.text(auth(token)))
            for try await _ in inbound.messages(maxSize: 1 << 20) {}
        }
    }

    @Test("bytes cross both ways and come back whole")
    func splices() async throws {
        let echo = try await EchoService.start()
        let sent = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let received = ReceivedBytes()
        _ = try await application().test(.live) { client in
            try await client.ws("/_bloom/v1/proxy?port=\(echo.port)") { inbound, outbound, _ in
                try await outbound.write(.text(Self.auth(issuer.session(issuedAt: clock.now))))
                // Many frames of the largest size a client may send, and far more than one TCP
                // read, so the splice has to carry it in pieces and keep them in order. Written
                // beside the reads rather than before them, because an echo that cannot hand its
                // bytes back stops reading, and a writer waiting on it would wait for ever.
                let writing = Task {
                    for start in stride(from: 0, to: sent.count, by: MachineSocket.maximumFrame) {
                        let end = min(start + MachineSocket.maximumFrame, sent.count)
                        try await outbound.write(.binary(ByteBuffer(bytes: sent[start..<end])))
                    }
                }
                defer { writing.cancel() }
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    guard case .binary(let buffer) = message else { continue }
                    if await received.append(buffer) >= sent.count { break }
                }
                try await writing.value
            }
        }
        let bytes = await received.bytes
        #expect(bytes.count == sent.count)
        #expect(bytes == sent)
        try await echo.close()
    }

    @Test("a port nothing listens on closes with the retryable code")
    func nothingListening() async throws {
        let echo = try await EchoService.start()
        let port = echo.port
        try await echo.close()
        try await application().test(.live) { client in
            let frame = try await Self.refusal(client, port: port, token: issuer.session(issuedAt: clock.now))
            #expect(frame?.closeCode == WebSocketErrorCode(codeNumber: 4502))
        }
    }

    @Test("Bloom's own port is refused even though something answers on it")
    func reservedPort() async throws {
        let echo = try await EchoService.start()
        try await application(reserved: [echo.port]).test(.live) { client in
            let frame = try await Self.refusal(client, port: echo.port, token: issuer.session(issuedAt: clock.now))
            #expect(frame?.closeCode == WebSocketErrorCode(codeNumber: 4403))
            #expect(frame?.reason?.contains("\(echo.port)") == true)
        }
        try await echo.close()
    }

    @Test("somebody who may only look is refused before anything is dialled")
    func viewOnly() async throws {
        let echo = try await EchoService.start()
        try await application().test(.live) { client in
            let viewer = issuer.session(abilities: ["view", "prompt"], issuedAt: clock.now)
            let frame = try await Self.refusal(client, port: echo.port, token: viewer)
            #expect(frame?.closeCode == WebSocketErrorCode(codeNumber: 4401))
        }
        #expect(await echo.accepted == 0)
        try await echo.close()
    }

    @Test("a service bound where the first host is not is reached at the next")
    func fallsThroughHosts() async throws {
        // Nothing listens on ::1 at this port, so the first attempt fails whether or not this host
        // has IPv6 loopback at all, and the forward has to find the service at the second.
        let echo = try await EchoService.start()
        let received = ReceivedBytes()
        _ = try await application(hosts: ["::1", "127.0.0.1"]).test(.live) { client in
            try await client.ws("/_bloom/v1/proxy?port=\(echo.port)") { inbound, outbound, _ in
                try await outbound.write(.text(Self.auth(issuer.session(issuedAt: clock.now))))
                try await outbound.write(.binary(ByteBuffer(string: "SELECT 1")))
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    guard case .binary(let buffer) = message else { continue }
                    if await received.append(buffer) >= 8 { return }
                }
            }
        }
        #expect(await received.bytes == Array("SELECT 1".utf8))
        try await echo.close()
    }

    @Test("removing somebody's access closes a forward they have open")
    func revokeCloses() async throws {
        let echo = try await EchoService.start()
        let connections = TerminalConnections()
        try await application(connections: connections).test(.live) { client in
            let frame = try await client.ws("/_bloom/v1/proxy?port=\(echo.port)") { inbound, outbound, _ in
                try await outbound.write(.text(Self.auth(issuer.session(issuedAt: clock.now))))
                try await outbound.write(.binary(ByteBuffer(string: "ping")))
                var revoked = false
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    // The echo proves the forward is registered and live; only then is the revoke
                    // sent, so it cannot land before there is a connection to close.
                    guard case .binary = message, !revoked else { continue }
                    revoked = true
                    await connections.revoke(userID: TestTokenIssuer.defaultUserID)
                }
            }
            #expect(frame?.closeCode == WebSocketErrorCode(codeNumber: 4401))
        }
        #expect(await connections.count == 0)
        try await echo.close()
    }

    @Test("a forward closes when its token runs out")
    func expiryCloses() async throws {
        // The deadline is read from the real clock, so this token is issued against it and lives a
        // second. What is asserted is that the close arrives and says why, not when.
        let now = TestClock(Date())
        let echo = try await EchoService.start()
        try await application(clock: now).test(.live) { client in
            let brief = issuer.session(issuedAt: now.now, lifetime: 1)
            let frame = try await Self.refusal(client, port: echo.port, token: brief)
            #expect(frame?.closeCode == .policyViolation)
            #expect(frame?.reason == "token_expired")
        }
        try await echo.close()
    }

    @Test("the service hanging up ends the forward cleanly")
    func serviceHangsUp() async throws {
        let echo = try await EchoService.start(hangUpAfterFirstRead: true)
        try await application().test(.live) { client in
            let frame = try await client.ws("/_bloom/v1/proxy?port=\(echo.port)") { inbound, outbound, _ in
                try await outbound.write(.text(Self.auth(issuer.session(issuedAt: clock.now))))
                try await outbound.write(.binary(ByteBuffer(string: "bye")))
                for try await _ in inbound.messages(maxSize: 1 << 20) {}
            }
            #expect(frame?.closeCode == .normalClosure)
        }
        try await echo.close()
    }
}

/// Bytes gathered across frames, from inside a WebSocket handler.
actor ReceivedBytes {
    private(set) var bytes: [UInt8] = []

    func append(_ buffer: ByteBuffer) -> Int {
        bytes.append(contentsOf: buffer.readableBytesView)
        return bytes.count
    }
}

/// A TCP service on loopback that writes back whatever it reads: a database, as far as the proxy
/// can tell.
struct EchoService {
    let channel: any Channel
    let port: Int
    private let counter: AcceptCounter

    var accepted: Int {
        get async { await counter.count }
    }

    static func start(hangUpAfterFirstRead: Bool = false) async throws -> EchoService {
        let counter = AcceptCounter()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                Task { await counter.increment() }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(Echo(hangUp: hangUpAfterFirstRead))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return EchoService(channel: channel, port: channel.localAddress?.port ?? 0, counter: counter)
    }

    func close() async throws {
        try await channel.close()
    }

    private final class Echo: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let hangUp: Bool

        init(hangUp: Bool) { self.hangUp = hangUp }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if hangUp {
                context.close(promise: nil)
            } else {
                context.writeAndFlush(data, promise: nil)
            }
        }
    }
}

actor AcceptCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

import BloomCore
import BloomProtocol
import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import NIOPosix

/// `GET /_bloom/v1/proxy?port=`: one TCP port inside this workspace, over a WebSocket.
///
/// **This is the whole of port forwarding, and it is a length of hose.** A client connects, says
/// which port, and from then on every binary frame is written to `127.0.0.1:<port>` and everything
/// that port says comes back as a binary frame. Nothing here parses what goes through, which is why
/// one route serves PostgreSQL, Redis, a dev server and a debugger without knowing the difference.
///
/// **It rides the machine's own URL rather than Fly's proxy API.** Reaching a Sprite's TCP port
/// from outside otherwise needs the Sprites organisation token, which opens every Sprite in the
/// organisation and therefore may never leave runbloom.app. Bloom Runner is already standing inside
/// this one workspace with the machine's own authentication in front of it, so the forward needs no
/// new authority at all. Measured end to end on a real Sprite on 22 September 2026, with a Mac
/// client and `psql`, before any of this was written.
///
/// **The token is the first text frame**, as it is for the terminal: a browser's `WebSocket` cannot
/// send a header, so every client takes one path and there is one path to test. A connection that
/// has not authenticated within five seconds is closed.
///
/// **Bloom's own ports are refused**, from the list the machine holds rather than from a copy of
/// the numbers, because both of them can be moved by the environment.
enum ProxyRoute {
    /// Why a proxy socket closed, in codes a client can act on rather than sentences it must read.
    /// 4401 and 4403 are not retryable; 4502 is, once whatever should be listening is.
    enum Refusal: UInt16 {
        case unauthenticated = 4401
        case portRefused = 4403
        case cannotReachPort = 4502
    }

    struct Dependencies: Sendable {
        let verifier: TokenVerifier
        let connections: TerminalConnections
        let reservedPorts: [Int]
        /// Where a forward connects, in order: this machine's loopback, IPv4 first. `::1` is
        /// there because `listening_ports` reads `/proc/net/tcp6` too, and a service bound to
        /// `[::1]` alone would otherwise be listed as forwardable and then refused as unreachable.
        var hosts: [String] = ["127.0.0.1", "::1"]
    }

    /// The largest message a client's frames may add up to. Each frame is `MachineSocket.maximumFrame`
    /// at most; this bounds what one message may hold once they are joined.
    static let maximumMessage = 1 << 20

    static func register(on router: Router<WorkspaceRequestContext>, dependencies: Dependencies) {
        router.ws("/_bloom/v1/proxy") { request, _ in
            guard let raw = request.uri.queryParameters.get("port"), let port = Int(raw), (1...65_535).contains(port) else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let raw = context.request.uri.queryParameters.get("port"), let port = Int(raw) else { return }
            try await serve(port: port, inbound: inbound, outbound: outbound, dependencies: dependencies)
        }
    }

    /// The auth frame's token, verified for this workspace and for a forward.
    ///
    /// **A forward needs `terminal`, not `view`.** It reaches any port inside the machine, which is
    /// as much of the machine as a shell is, so somebody who may only read a workspace may not open
    /// its database on their own Mac. A function of its own so every refusal can be tested without
    /// a socket.
    static func authorise(_ raw: String, verifier: TokenVerifier) async throws -> WorkspaceToken {
        let token = try await verifier.verify(raw, as: .session)
        guard token.abilities.contains("view"), token.abilities.contains("terminal") else {
            throw RemoteFailure(.missingAbility, "Your access to this Bloom Cloud workspace does not include forwarding a port.")
        }
        try token.refuseIfMintedForAnAgent()
        return token
    }

    /// Whether a port may be forwarded at all, and why not when it may not.
    ///
    /// **Bloom's own ports are the one hard refusal.** Forwarding the control port would hand a
    /// client the machine's own API on a local socket, and forwarding the model gateway would hand
    /// out model authority; both are reachable from inside the workspace and neither is a thing a
    /// person wants on `localhost`.
    static func refusal(forwarding port: Int, reserved: [Int]) -> String? {
        guard (1...65_535).contains(port) else { return "That is not a port." }
        guard !reserved.contains(port) else { return "Bloom uses port \(port) on this machine, so it cannot be forwarded." }
        return nil
    }

    private static func serve(
        port: Int, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, dependencies: Dependencies
    ) async throws {
        let connections = dependencies.connections
        guard await connections.admitUnauthenticated() else {
            try await outbound.close(.policyViolation, reason: "Too many connections are opening. Try again in a moment.")
            return
        }
        var waiting = true
        defer { if waiting { Task { await connections.authenticated() } } }
        var messages = inbound.messages(maxSize: maximumMessage).makeAsyncIterator()
        // Closing the socket is what ends a read nobody answers, so the deadline closes it rather
        // than trying to cancel the read. The same five seconds as the terminal.
        let deadline = Task {
            try await Task.sleep(for: TerminalRoute.authenticationDeadline)
            try await outbound.close(.init(codeNumber: Int(Refusal.unauthenticated.rawValue)), reason: "Authenticate within five seconds.")
        }
        let first = try await messages.next()
        deadline.cancel()
        waiting = false
        await connections.authenticated()
        guard let first, case .text(let text) = first,
              let frame = try? WireJSON.decode(TerminalControlFrame.self, from: Data(text.utf8)),
              case .auth(let raw) = frame else {
            try await close(outbound, .unauthenticated, "Send an auth frame first.")
            return
        }
        let token: WorkspaceToken
        do {
            token = try await authorise(raw, verifier: dependencies.verifier)
        } catch {
            try await close(outbound, .unauthenticated, RemoteFailure.wire(error).message)
            return
        }
        if let refused = refusal(forwarding: port, reserved: dependencies.reservedPorts) {
            try await close(outbound, .portRefused, refused)
            return
        }

        // Registered like a terminal connection, so revoking somebody's access closes their
        // forwards with their shells rather than leaving a socket into the machine open. What it
        // closes is the socket itself: the client answers the close, the loop below ends and the
        // TCP side goes with it. Cancelling a task instead, as this first did, stopped bytes
        // coming back and left the client free to go on writing into the database.
        let connection = await connections.add(userID: token.author?.userID) {
            try? await close(outbound, .unauthenticated, "Your access to this Bloom Cloud workspace was removed.")
        }
        defer { Task { await connections.remove(connection) } }
        // A revoke that landed while the token was being verified found no socket to close.
        if await dependencies.verifier.revocations.isRevoked(token.subject, issuedAt: token.issuedAt) {
            try await close(outbound, .unauthenticated, "Your access to this Bloom Cloud workspace was removed.")
            return
        }

        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            channel = try await connect(hosts: dependencies.hosts, port: port)
        } catch {
            try await close(outbound, .cannotReachPort, "Nothing is listening on port \(port) in this workspace.")
            return
        }

        // **A forward does not outlive its token**, for the reason a terminal does not: somebody
        // removed from the team gets no fresh token, so their forward closes within one lifetime
        // even if the revoke never arrives. `reauth` moves the deadline on, and a client sends it
        // only while bytes are moving, because a frame on a quiet connection would keep a Sprite
        // awake that should be allowed to pause.
        let expiry = TerminalExpiry(expiresAt: token.expiresAt)
        try await channel.executeThenClose { reader, writer in
            let toSocket = Task {
                for try await chunk in reader {
                    // One read of the socket can be 64 KiB, and `write(.binary:)` sends whatever it
                    // is given as a single frame. A client built on Hummingbird refuses a frame over
                    // 16 KiB and closes, which is how the end to end test found this at 128 KiB
                    // in. So the machine sends by the same limit it holds clients to.
                    var remaining = chunk
                    while let slice = remaining.readSlice(length: min(remaining.readableBytes, MachineSocket.maximumFrame)),
                          slice.readableBytes > 0 {
                        try await outbound.write(.binary(slice))
                    }
                }
                try await outbound.close(.normalClosure, reason: nil)
            }
            let tokenDeadline = Task {
                try await TerminalRoute.closeAtExpiry(expiry) {
                    try await outbound.close(.policyViolation, reason: "token_expired")
                }
            }
            defer {
                toSocket.cancel()
                tokenDeadline.cancel()
            }
            while let message = try await messages.next() {
                switch message {
                case .binary(let buffer):
                    try await writer.write(buffer)
                // A text frame is never data: writing a stray control frame into a database
                // connection would corrupt the stream. `reauth` from the same person, still
                // allowed to forward, extends the deadline; anything else is ignored.
                case .text(let text):
                    guard let frame = try? WireJSON.decode(TerminalControlFrame.self, from: Data(text.utf8)),
                          case .reauth(let raw) = frame,
                          let fresh = try? await authorise(raw, verifier: dependencies.verifier),
                          fresh.author?.userID == token.author?.userID else { continue }
                    await expiry.extend(to: fresh.expiresAt)
                }
            }
            writer.finish()
        }
    }

    private static func close(_ outbound: WebSocketOutboundWriter, _ refusal: Refusal, _ reason: String) async throws {
        try await outbound.close(.init(codeNumber: Int(refusal.rawValue)), reason: reason)
    }

    /// One TCP connection to a port inside this machine, from the first host that answers.
    static func connect(hosts: [String], port: Int) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        var failure: (any Error)?
        for host in hosts {
            do {
                return try await connect(host: host, port: port)
            } catch {
                failure = error
            }
        }
        throw failure ?? ChannelError.inappropriateOperationForState
    }

    static func connect(host: String, port: Int) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            }
    }
}

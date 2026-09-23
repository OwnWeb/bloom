@testable import BloomClient
import BloomProtocol
import Darwin
import Foundation
import Network
import Testing

/// A port inside a Cloud workspace, listening on this Mac.
///
/// The pure halves first: where the socket goes, what its first frame says, what a close means and
/// when a token is renewed. Then the listener on real loopback ports, because falling through a
/// taken port is a thing Network reports after the fact and only a real bind shows it. Then one
/// forward end to end against a fake machine, which is Network's own WebSocket server playing the
/// part of `ProxyRoute`.
///
/// The time limit is a cap on infinity, not a measurement: every wait here is for an event, and
/// what it guards against is one that never comes.
@Suite("Forwarding a workspace's port to this Mac", .timeLimit(.minutes(1)))
struct PortForwardTests {
    // MARK: - The socket and its first frame

    @Test("the socket is the machine's proxy route over wss, with the port as a query")
    func socketURL() {
        let url = PortForward.socketURL(machine: URL(string: "https://m-01k5.runbloom.app")!, port: 5432)
        #expect(url.absoluteString == "wss://m-01k5.runbloom.app/_bloom/v1/proxy?port=5432")
    }

    @Test("a machine on plain http, which only a local rig is, gets ws")
    func socketURLForARig() {
        let url = PortForward.socketURL(machine: URL(string: "http://127.0.0.1:8081")!, port: 6379)
        #expect(url.absoluteString == "ws://127.0.0.1:8081/_bloom/v1/proxy?port=6379")
    }

    @Test("the first frame is the terminal's auth frame, carrying the token")
    func authFrame() throws {
        let frame = PortForward.authFrame("token-1")
        #expect(try WireJSON.decode(TerminalControlFrame.self, from: Data(frame.utf8)) == .auth(token: "token-1"))
    }

    // MARK: - What a close says about the whole forward

    @Test("no ability to forward, and Bloom's own port, refuse the whole forward in the machine's words")
    func refusals() {
        #expect(PortForward.verdict(closeCode: 4401, reason: "Your access was removed.") == "Your access was removed.")
        #expect(PortForward.verdict(closeCode: 4403, reason: "Bloom uses port 8080 on this machine, so it cannot be forwarded.")?
            .contains("8080") == true)
        #expect(PortForward.verdict(closeCode: 4403, reason: "") != nil)
    }

    @Test("nothing listening yet, and an ordinary close, are about one connection only")
    func notRefusals() {
        #expect(PortForward.verdict(closeCode: 4502, reason: "Nothing is listening on port 5432 in this workspace.") == nil)
        #expect(PortForward.verdict(closeCode: 1000, reason: nil) == nil)
        #expect(PortForward.verdict(closeCode: 1008, reason: "token_expired") == nil)
        #expect(PortForward.verdict(closeCode: 0, reason: nil) == nil)
    }

    // MARK: - Renewing a token on a long connection

    @Test("no renewal inside the interval, however many bytes move")
    func renewalWaitsForTheInterval() async {
        let start = ContinuousClock.now
        let renewal = PortForward.Renewal(token: "old", credentials: { (URL(string: "https://m")!, "new") }, checked: start)
        #expect(await renewal.due(at: start + .seconds(5)) == nil)
    }

    @Test("a changed token is sent once the interval has passed, and only once")
    func renewalSendsAChangedToken() async {
        let start = ContinuousClock.now
        let renewal = PortForward.Renewal(token: "old", credentials: { (URL(string: "https://m")!, "new") }, checked: start)
        #expect(await renewal.due(at: start + PortForward.Renewal.interval) == "new")
        #expect(await renewal.due(at: start + PortForward.Renewal.interval * 3) == nil)
    }

    @Test("the token the machine already has is not sent again")
    func renewalSkipsAnUnchangedToken() async {
        let start = ContinuousClock.now
        let renewal = PortForward.Renewal(token: "same", credentials: { (URL(string: "https://m")!, "same") }, checked: start)
        #expect(await renewal.due(at: start + PortForward.Renewal.interval) == nil)
    }

    // MARK: - The local port

    @Test("a local port somebody else holds is passed over for the next candidate")
    func fallsThroughATakenPort() async throws {
        let held = try HeldPort()
        let free = try freePort()
        let forward = PortForward(remotePort: 5432, localCandidates: [held.port, free]) { nil }
        await forward.start()
        #expect(await forward.state == .live(localPort: free))
        await forward.stop()
    }

    @Test("with every candidate taken, the forward says so rather than claiming one")
    func noCandidateFree() async throws {
        let held = try HeldPort()
        let forward = PortForward(remotePort: 5432, localCandidates: [held.port]) { nil }
        await forward.start()
        #expect(await forward.state == .failed("No local port was free for this forward."))
    }

    @Test("stopping a forward gives its local port back")
    func stopReleasesThePort() async throws {
        let port = try freePort()
        let first = PortForward(remotePort: 5432, localCandidates: [port]) { nil }
        await first.start()
        #expect(await first.state == .live(localPort: port))
        await first.stop()
        let second = PortForward(remotePort: 5432, localCandidates: [port]) { nil }
        await second.start()
        #expect(await second.state == .live(localPort: port))
        await second.stop()
    }

    // MARK: - End to end

    @Test("a client on this Mac reaches the machine, and the machine hears the token first")
    func splicesToTheMachine() async throws {
        let machine = try await FakeMachine.start(.echo)
        let local = try freePort()
        let forward = PortForward(remotePort: 5432, localCandidates: [local]) {
            (machine: URL(string: "http://127.0.0.1:\(machine.port)")!, token: "token-1")
        }
        await forward.start()
        let reply = try await LoopbackClient.exchange(port: local, sending: Data("SELECT 1".utf8))
        #expect(reply == Data("SELECT 1".utf8))
        #expect(machine.firstText == PortForward.authFrame("token-1"))
        await forward.stop()
        machine.stop()
    }

    @Test("a refusal from the machine refuses the forward and lets its local port go")
    func refusalStopsTheForward() async throws {
        let machine = try await FakeMachine.start(.refuse(4403, "Bloom uses port 8080 on this machine, so it cannot be forwarded."))
        let local = try freePort()
        let forward = PortForward(remotePort: 8080, localCandidates: [local]) {
            (machine: URL(string: "http://127.0.0.1:\(machine.port)")!, token: "token-1")
        }
        await forward.start()
        _ = try? await LoopbackClient.exchange(port: local, sending: Data("GET / HTTP/1.1\r\n\r\n".utf8))
        var reason: String?
        for await state in forward.states {
            if case .refused(let why) = state {
                reason = why
                break
            }
        }
        #expect(reason?.contains("8080") == true)
        // The port is free again, so a second forward can take it.
        let again = PortForward(remotePort: 5432, localCandidates: [local]) { nil }
        await again.start()
        #expect(await again.state == .live(localPort: local))
        await again.stop()
        machine.stop()
    }
}

// MARK: - Support

/// A port nothing holds at the moment it is asked for.
private func freePort() throws -> Int {
    let held = try HeldPort()
    return held.port
}

/// A TCP port on 127.0.0.1, bound and listening for as long as this value lives.
private final class HeldPort {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && listen(descriptor, 1) == 0
                    && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit { close(descriptor) }
}

/// One TCP connection from "a database client": send some bytes, read what comes back.
private enum LoopbackClient {
    static func exchange(port: Int, sending data: Data) async throws -> Data {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: .global())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: data.count, maximumLength: 1 << 16) { received, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: received ?? Data())
                }
            }
        }
    }
}

/// `ProxyRoute` as far as a client can tell: a WebSocket server that reads the auth frame and then
/// either echoes every binary frame or closes with a refusal.
private final class FakeMachine: @unchecked Sendable {
    enum Behaviour {
        case echo
        case refuse(UInt16, String)
    }

    let port: Int
    private let listener: NWListener
    private let lock = NSLock()
    private var texts: [String] = []

    var firstText: String? { lock.withLock { texts.first } }

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start(_ behaviour: Behaviour) async throws -> FakeMachine {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let box = Box()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            box.machine?.receive(on: connection, behaviour: behaviour)
        }
        let settled = Latch()
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if settled.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    if settled.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let machine = FakeMachine(listener: listener, port: port)
        box.machine = machine
        return machine
    }

    func stop() { listener.cancel() }

    private func receive(on connection: NWConnection, behaviour: Behaviour) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil, let context,
                  let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            else { return }
            switch metadata.opcode {
            case .text:
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                self.lock.withLock { self.texts.append(text) }
                if case .refuse(let code, let reason) = behaviour {
                    Self.close(connection, code: code, reason: reason)
                    return
                }
            case .binary:
                Self.send(data ?? Data(), opcode: .binary, on: connection)
            default:
                break
            }
            self.receive(on: connection, behaviour: behaviour)
        }
    }

    private static func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private static func close(_ connection: NWConnection, code: UInt16, reason: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .privateCode(code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: Data(reason.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Lets the connection handler, set before the listener starts, reach the machine made after.
    private final class Box: @unchecked Sendable {
        var machine: FakeMachine?
    }

    /// True for the first caller only, for a continuation more than one state could resume.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}

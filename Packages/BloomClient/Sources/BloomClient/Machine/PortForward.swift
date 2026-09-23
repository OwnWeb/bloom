import BloomProtocol
import Foundation
import Network
import Synchronization

/// One port inside a Cloud workspace, listening on this Mac.
///
/// **What a database client connects to.** Bloom binds a local port, and every connection to it is
/// carried over a WebSocket to `GET /_bloom/v1/proxy?port=` on the workspace's machine, where Bloom
/// Runner opens the real port and copies bytes. TablePlus, `psql` and a browser see a service on
/// `localhost` and never learn otherwise.
///
/// **A socket per connection, opened when the client connects.** Not one long-lived tunnel: a
/// Sprite pauses about thirty seconds after the last activity and every connection through it dies,
/// so a tunnel held open across a pause would be a tunnel that is quietly dead. Connecting per
/// connection means the pause is invisible to anything that reconnects, and measured waking on a
/// real Sprite took 1.6 seconds for the whole round trip.
///
/// **Loopback only.** The listener is pinned to 127.0.0.1, so a forward is reachable from this Mac
/// and from nothing else on the network.
public actor PortForward {
    public enum State: Sendable, Hashable {
        case opening
        /// Listening on this Mac. The port a person copies.
        case live(localPort: Int)
        /// The machine refused it and will go on refusing: the wrong ability, or one of Bloom's own
        /// ports. Retrying does not help, and the sentence is the machine's.
        case refused(String)
        /// It stopped working for a reason that may not last, such as nothing listening yet.
        case failed(String)
    }

    /// What a forward needs to reach its machine, read fresh for every connection so a renewed
    /// token is used without reopening the forward.
    public typealias Credentials = @Sendable () async -> (machine: URL, token: String)?

    public nonisolated let remotePort: Int
    private let credentials: Credentials
    private let candidates: [Int]
    private let session: URLSession
    private var listener: NWListener?
    private var live: [ObjectIdentifier: (connection: NWConnection, socket: URLSessionWebSocketTask)] = [:]

    public private(set) var state: State = .opening {
        didSet { if state != oldValue { continuation.yield(state) } }
    }

    public nonisolated let states: AsyncStream<State>
    private nonisolated let continuation: AsyncStream<State>.Continuation

    public init(remotePort: Int, localCandidates: [Int], session: URLSession = .shared, credentials: @escaping Credentials) {
        self.remotePort = remotePort
        self.candidates = localCandidates
        self.session = session
        self.credentials = credentials
        (states, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(16))
    }

    /// The address a forward's URL uses. A forward is always on this Mac, so only the port varies.
    public static func url(scheme: String, localPort: Int) -> URL? {
        URL(string: "\(scheme)://127.0.0.1:\(localPort)")
    }

    /// Binds the first candidate port nothing else has, and starts listening.
    ///
    /// **The candidates matter in order.** The first is a stable choice for this workspace and
    /// port, so a connection saved in a database client keeps working; the rest are there because
    /// another workspace, another copy of Bloom or anything else on this Mac may already hold it.
    ///
    /// **A candidate is only taken once its listener says it is ready.** `NWListener` binds when it
    /// starts, not when it is made, so a port somebody else holds is reported afterwards, as a
    /// failed state. The first version called the forward live the moment the listener existed,
    /// which meant a taken port never fell through to the next candidate: it showed a `localhost`
    /// address that belonged to something else, then turned red.
    public func start() async {
        guard listener == nil else { return }
        for candidate in candidates {
            let accept: @Sendable (NWConnection) -> Void = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            guard let listener = await Self.listen(on: candidate, accept: accept) else { continue }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                Task { await self?.stopped(because: "The local port could not be held: \(error.localizedDescription)") }
            }
            self.listener = listener
            state = .live(localPort: candidate)
            return
        }
        state = .failed("No local port was free for this forward.")
    }

    /// A listener on `127.0.0.1:<port>` that has actually bound, or nil when the port is taken.
    /// `accept` is set before it starts, because Network requires a handler then and a connection
    /// in the gap before a later one would be dropped.
    static func listen(on candidate: Int, accept: @escaping @Sendable (NWConnection) -> Void) async -> NWListener? {
        guard let number = UInt16(exactly: candidate), let port = NWEndpoint.Port(rawValue: number), number > 0 else { return nil }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let settled = Once()
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            listener.newConnectionHandler = accept
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if settled.claim() { continuation.resume(returning: true) }
                // A port in use is reported as `failed` or, on some releases, as `waiting` for an
                // address that will never come free. Either way it is somebody else's.
                case .failed, .waiting, .cancelled:
                    if settled.claim() { continuation.resume(returning: false) }
                case .setup: break
                @unknown default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        guard ready else {
            listener.cancel()
            return nil
        }
        return listener
    }

    /// Stops listening and closes every connection through it. Returns once the local port is
    /// free, so forwarding the same port again straight after lands on the same address.
    public func stop() async {
        await closeEverything()
        continuation.finish()
    }

    private func closeEverything() async {
        let listening = listener
        listener = nil
        if let listening { await Self.cancel(listening) }
        for entry in live.values {
            entry.connection.cancel()
            entry.socket.cancel(with: .goingAway, reason: nil)
        }
        live.removeAll()
    }

    private func stopped(because reason: String) {
        listener?.cancel()
        listener = nil
        state = .failed(reason)
    }

    /// The machine said no in a way that will not change on a retry. The local port is let go at
    /// once, because a `localhost` address that accepts a connection and then drops it every time
    /// is worse than one that refuses to connect at all.
    private func refused(_ reason: String) async {
        await closeEverything()
        state = .refused(reason)
    }

    /// Cancels a listener and waits for Network to say it has let go of the port.
    ///
    /// **`cancel()` returns before the socket is closed.** The close happens on the listener's
    /// queue and is reported as a state, so a forward stopped and started again at once asked for
    /// a port its own previous listener still held, and fell through to its second candidate: the
    /// address a saved TablePlus connection used moved, which is the one thing the stable first
    /// candidate is for. The macOS runner found it in the first run of these tests.
    static func cancel(_ listener: NWListener) async {
        let settled = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    if settled.claim() { continuation.resume() }
                default: break
                }
            }
            listener.cancel()
        }
    }

    /// One connection from something on this Mac: open the socket to the machine, then splice.
    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.start(queue: .global(qos: .userInitiated))
        Task { [weak self] in
            guard let self else { return connection.cancel() }
            await self.open(connection, id: id)
        }
    }

    private func open(_ connection: NWConnection, id: ObjectIdentifier) async {
        guard let first = await credentials() else {
            connection.cancel()
            note(.failed("This Bloom Cloud workspace is not ready to forward a port yet."))
            return
        }
        let socket = session.webSocketTask(with: Self.socketURL(machine: first.machine, port: remotePort))
        socket.maximumMessageSize = 1 << 20
        socket.resume()
        do {
            try await socket.send(.string(Self.authFrame(first.token)))
        } catch {
            connection.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        live[id] = (connection, socket)
        let renewal = Renewal(token: first.token, credentials: credentials)
        let close = await Self.splice(connection: connection, socket: socket, renewal: renewal)
        release(id: id)
        if let verdict = Self.verdict(closeCode: close.code, reason: close.reason) {
            await refused(verdict)
        }
    }

    private func release(id: ObjectIdentifier) {
        guard let entry = live.removeValue(forKey: id) else { return }
        entry.connection.cancel()
        entry.socket.cancel(with: .goingAway, reason: nil)
    }

    private func note(_ state: State) {
        // A live forward stays live: one connection failing is a client's problem, not the
        // forward's, and a row that flickers to red every time a pool closes a connection is worse
        // than one that says nothing.
        if case .live = self.state, case .failed = state { return }
        self.state = state
    }

    /// What one connection's close says about the whole forward, when it says anything.
    ///
    /// 4401 and 4403 are `ProxyRoute`'s refusals that no retry fixes: no ability to forward, or
    /// one of Bloom's own ports. 4502, nothing listening yet, is about this connection only, since
    /// the next may find the service up, and so is every ordinary close.
    static func verdict(closeCode: Int, reason: String?) -> String? {
        switch closeCode {
        case 4401: reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Your access to this workspace does not include forwarding a port."
        case 4403: reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Bloom uses this port on the workspace, so it cannot be forwarded."
        default: nil
        }
    }

    /// Both directions at once, until either end hangs up, and how the machine closed if it did.
    ///
    /// **Neither pump answers task cancellation while it waits on a socket**, so when one side
    /// ends, both sockets are closed, which is what ends the other wait. The first version only
    /// cancelled the group, and a client that disconnected left the WebSocket, and the machine's
    /// connection to the database behind it, open until the machine gave up on it.
    private static func splice(
        connection: NWConnection, socket: URLSessionWebSocketTask, renewal: Renewal
    ) async -> (code: Int, reason: String?) {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pumpToSocket(connection: connection, socket: socket, renewal: renewal) }
            group.addTask { await pumpToConnection(connection: connection, socket: socket, renewal: renewal) }
            await group.next()
            // Read before this side closes the socket, so the code is the machine's own.
            let close = (code: socket.closeCode.rawValue, reason: socket.closeReason.map { String(decoding: $0, as: UTF8.self) })
            connection.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
            group.cancelAll()
            return close
        }
    }

    private static func pumpToSocket(connection: NWConnection, socket: URLSessionWebSocketTask, renewal: Renewal) async {
        while !Task.isCancelled {
            let chunk: Data?
            do {
                // No larger than the machine accepts in one frame. See `MachineSocket`.
                chunk = try await connection.nextChunk(maximumLength: MachineSocket.maximumFrame)
            } catch {
                return
            }
            guard let chunk else { return }
            if chunk.isEmpty { continue }
            do {
                try await renewal.renew(on: socket)
                try await socket.send(.data(chunk))
            } catch {
                return
            }
        }
    }

    private static func pumpToConnection(connection: NWConnection, socket: URLSessionWebSocketTask, renewal: Renewal) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                return
            }
            let data: Data
            switch message {
            case .data(let bytes): data = bytes
            // The machine sends bytes as binary frames. A text frame is not data and writing it
            // into the client's stream would corrupt whatever protocol it is speaking.
            case .string: continue
            @unknown default: continue
            }
            do {
                try await connection.send(data)
                try await renewal.renew(on: socket)
            } catch {
                return
            }
        }
    }

    static func socketURL(machine: URL, port: Int) -> URL {
        var components = URLComponents(url: machine.appending(path: "_bloom/v1/proxy"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "port", value: String(port))]
        return components.url!
    }

    static func authFrame(_ token: String) -> String {
        frame(.auth(token: token))
    }

    static func frame(_ frame: TerminalControlFrame) -> String {
        (try? WireJSON.encode(frame)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension PortForward {
    /// A fresh token for one long connection, handed over only while bytes are moving on it.
    ///
    /// **The machine closes a forward whose token has run out**, as it does a terminal, so that
    /// somebody removed from a team loses their open database connection within one token's life
    /// even if the revoke never reaches the machine. A terminal renews on a four minute timer. A
    /// forward must not: a frame on a quiet connection is activity, and a Sprite that should have
    /// paused thirty seconds after the last query would stay awake for as long as TablePlus stays
    /// open. So the check rides on traffic, at most every thirty seconds, and a connection that
    /// goes quiet past its token's life is closed by the machine and reopened by the client.
    actor Renewal {
        static let interval: Duration = .seconds(30)

        private var sent: String
        private var checked: ContinuousClock.Instant
        private let credentials: Credentials

        init(token: String, credentials: @escaping Credentials, checked: ContinuousClock.Instant = .now) {
            sent = token
            self.credentials = credentials
            self.checked = checked
        }

        /// The token to send now, or nil when none is due or the one the machine has is current.
        func due(at now: ContinuousClock.Instant = .now) async -> String? {
            guard now - checked >= Self.interval else { return nil }
            checked = now
            guard let fresh = await credentials()?.token, fresh != sent else { return nil }
            sent = fresh
            return fresh
        }

        func renew(on socket: URLSessionWebSocketTask) async throws {
            guard let token = await due() else { return }
            try await socket.send(.string(PortForward.frame(.reauth(token: token))))
        }
    }
}

/// True for exactly one caller, for a continuation that more than one callback could resume.
private final class Once: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}

private extension NWConnection {
    /// The next bytes from the client, or nil at the end of the stream.
    func nextChunk(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

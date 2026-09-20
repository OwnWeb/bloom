import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import Synchronization

/// runbloom.app's machine API, in process, on 127.0.0.1 and a port the system picks.
///
/// A real listening socket rather than a stubbed transport, because what these tests have to pin
/// is the request as it leaves the machine: the path, the method, the bearer header and the JSON,
/// through the same `HTTPClient` Bloom Runner uses. Every request is recorded, and every answer can
/// be scripted, either per turn for `start` or as one-shot answers queued for a method and path.
final class FakeControlServer: Sendable {
    struct RecordedRequest: Sendable {
        var method: String
        /// The path after `/api/machine/workspaces/{id}`, or the whole path for anything else.
        var path: String
        var authorization: String?
        var contentType: String?
        var idempotencyKey: String?
        var body: Data

        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    struct Scripted: Sendable {
        var status: Int
        var body: String?

        static let noContent = Scripted(status: 204, body: nil)

        /// A body written out as it arrives on the wire, for a test about a shape rather than a
        /// value: re-encoding it here would test this fake's encoder.
        static func raw(_ status: Int, _ body: String) -> Scripted {
            Scripted(status: status, body: body)
        }

        static func json(_ status: Int, _ object: [String: Any]) -> Scripted {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return Scripted(status: status, body: String(decoding: data, as: UTF8.self))
        }

        /// A granted start. `keys` is by wire agent name: `(key, identity, source)`.
        static func grant(
            turn: String = "",
            keys: [String: (key: String, identity: String, source: String)] = [:],
            environment: [String: String] = [:]
        ) -> Scripted {
            var agentKeys: [String: Any] = [:]
            for (agent, value) in keys {
                agentKeys[agent] = ["key": value.key, "identity": value.identity, "source": value.source]
            }
            return json(200, ["turn_id": turn, "state": "running", "agent_keys": agentKeys, "environment": environment])
        }

        /// runbloom.app's limit refusal: 429 with `retry_after` for the one that clears by itself,
        /// 403 for the rest.
        static func limit(_ limit: String, message: String, retryAfter: Int? = nil) -> Scripted {
            var body: [String: Any] = ["code": "limit_reached", "limit": limit, "message": message]
            if let retryAfter { body["retry_after"] = retryAfter }
            return json(limit == "concurrent_machines" ? 429 : 403, body)
        }

        static func refusal(status: Int = 403, code: String, message: String) -> Scripted {
            json(status, ["code": code, "message": message])
        }
    }

    private struct State {
        var requests: [RecordedRequest] = []
        var jwks: Data?
        var environment: [String: String] = [:]
        var membersBody = #"{"members": []}"#
        var starts: [String: Scripted] = [:]
        var defaultStart = Scripted.grant()
        var scripted: [String: [Scripted]] = [:]
        var turnsRegistered = 0
    }

    let workspaceID: String
    let secret: String
    let baseURL: String
    private let state: Mutex<State>
    private let server: Mutex<Task<Void, any Error>?>

    private init(workspaceID: String, secret: String, port: Int) {
        self.workspaceID = workspaceID
        self.secret = secret
        baseURL = "http://127.0.0.1:\(port)"
        state = Mutex(State())
        server = Mutex(nil)
    }

    static func start(workspaceID: String = "01jcloudworkspace000000000", secret: String = "secret-for-tests") async throws -> FakeControlServer {
        let (ports, portsContinuation) = AsyncStream<Int>.makeStream()
        let holder = Mutex<FakeControlServer?>(nil)
        var logger = Logger(label: "FakeControlServer")
        logger.logLevel = .critical

        let responder = CallbackResponder<BasicRequestContext> { request, _ in
            guard let fake = holder.withLock({ $0 }) else { return Response(status: .serviceUnavailable) }
            return try await fake.respond(to: request)
        }
        let app = Application(
            responder: responder,
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                portsContinuation.yield(channel.localAddress?.port ?? 0)
                portsContinuation.finish()
            },
            logger: logger
        )
        let task = Task {
            // A server that fails to bind never reports a port; finishing the stream here is what
            // turns that into a thrown error rather than a test that hangs.
            defer { portsContinuation.finish() }
            try await app.run()
        }

        var iterator = ports.makeAsyncIterator()
        guard let port = await iterator.next(), port > 0 else {
            task.cancel()
            try await task.value
            throw FakeControlServerError.didNotStart
        }
        let fake = FakeControlServer(workspaceID: workspaceID, secret: secret, port: port)
        fake.server.withLock { $0 = task }
        holder.withLock { $0 = fake }
        return fake
    }

    func stop() async {
        guard let task = server.withLock({ $0 }) else { return }
        task.cancel()
        _ = await task.result
    }

    // MARK: - What a test reads and scripts

    var requests: [RecordedRequest] { state.withLock { $0.requests } }

    func requests(_ method: String, _ path: String) -> [RecordedRequest] {
        requests.filter { $0.method == method && $0.path == path }
    }

    var jwks: Data? {
        get { state.withLock { $0.jwks } }
        set { state.withLock { $0.jwks = newValue } }
    }

    var environment: [String: String] {
        get { state.withLock { $0.environment } }
        set { state.withLock { $0.environment = newValue } }
    }

    /// The members answer as runbloom.app writes it, set by a test as raw JSON so the shape is the
    /// one being tested rather than one this fake re-encodes.
    var membersBody: String {
        get { state.withLock { $0.membersBody } }
        set { state.withLock { $0.membersBody = newValue } }
    }

    /// How `start` answers for this turn, every time it is asked.
    func setStart(turnID: String, response: Scripted) {
        state.withLock { $0.starts[turnID] = response }
    }

    /// How `start` answers for a turn with nothing set of its own.
    func setDefaultStart(_ response: Scripted) {
        state.withLock { $0.defaultStart = response }
    }

    /// Answers used once each, in order, before the endpoint's usual answer comes back. `path` is
    /// relative to the workspace, as `RecordedRequest.path` is.
    func script(_ method: String, _ path: String, _ responses: Scripted...) {
        state.withLock { $0.scripted["\(method) \(path)", default: []].append(contentsOf: responses) }
    }

    // MARK: - Answering

    private func respond(to incoming: Request) async throws -> Response {
        var request = incoming
        let body = Data(try await request.collectBody(upTo: 1 << 20).readableBytesView)
        let prefix = "/api/machine/workspaces/\(workspaceID)"
        let fullPath = request.uri.path
        let method = request.method.rawValue
        let path = fullPath.hasPrefix(prefix + "/") ? String(fullPath.dropFirst(prefix.count)) : fullPath

        let recorded = RecordedRequest(
            method: method,
            path: path,
            authorization: request.headers[.authorization],
            contentType: request.headers[.contentType],
            idempotencyKey: HTTPField.Name("Idempotency-Key").flatMap { request.headers[$0] },
            body: body
        )
        let scripted: Scripted? = state.withLock { state in
            state.requests.append(recorded)
            let key = "\(method) \(path)"
            guard var queue = state.scripted[key], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            state.scripted[key] = queue
            return next
        }

        if method == "GET", fullPath == "/.well-known/jwks.json" {
            guard let jwks else { return Self.response(.refusal(status: 404, code: "not_found", message: "No key set.")) }
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(bytes: jwks)))
        }
        guard fullPath.hasPrefix(prefix + "/") else {
            // A path of its own that a test scripted stands for another machine, such as the one
            // `RunbloomPeers` speaks to with a minted token rather than this workspace's secret.
            if let scripted { return Self.response(scripted) }
            return Self.response(.refusal(status: 404, code: "not_found", message: "No such workspace."))
        }
        guard recorded.authorization == "Bearer \(secret)" else {
            return Self.response(.refusal(status: 401, code: "invalid_workspace_secret", message: "The workspace secret is not valid."))
        }
        if let scripted { return Self.response(scripted) }
        return Self.response(usualAnswer(method: method, path: path))
    }

    private func usualAnswer(method: String, path: String) -> Scripted {
        let parts = path.split(separator: "/").map(String.init)
        switch (method, parts) {
        case ("POST", ["summary"]), ("POST", ["usage"]):
            return .noContent
        case ("GET", ["environment"]):
            return .json(200, ["environment": environment])
        case ("GET", ["members"]):
            return .raw(200, membersBody)
        case ("POST", ["addressed"]):
            return .json(200, ["ok": true])
        case ("POST", ["turns"]):
            let number = state.withLock { state in
                state.turnsRegistered += 1
                return state.turnsRegistered
            }
            return .json(201, ["turn_id": Self.turnID(number), "state": "queued"])
        case ("POST", let parts) where parts.count == 3 && parts[0] == "turns" && parts[2] == "start":
            return state.withLock { $0.starts[parts[1]] ?? $0.defaultStart }
        case ("DELETE", let parts) where parts.count == 2 && parts[0] == "turns":
            return .noContent
        case ("POST", ["git-credentials"]):
            return .json(200, ["token": "ghs_faketoken", "expires_at": "2026-09-17T10:00:00.250000Z", "username": "x-access-token"])
        default:
            return .refusal(status: 404, code: "not_found", message: "No such endpoint.")
        }
    }

    /// The turn ids the fake hands out, as a lowercase 26 character ULID-shaped string.
    static func turnID(_ number: Int) -> String {
        let digits = String(number)
        return "01jturn" + String(repeating: "0", count: 19 - digits.count) + digits
    }

    private static func response(_ scripted: Scripted) -> Response {
        guard let body = scripted.body else { return Response(status: .init(code: scripted.status)) }
        return Response(
            status: .init(code: scripted.status),
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: body))
        )
    }
}

enum FakeControlServerError: Error {
    case didNotStart
}

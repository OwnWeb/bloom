@testable import BloomClient
import Foundation

/// runbloom.app and a machine, answered from a script: each request is matched by method and path
/// suffix against the routes, in order, and recorded.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Answer {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        var lines: [String]?
        /// Thrown instead of answering.
        var failure: URLError?
    }

    struct Route {
        var method: String
        var suffix: String
        var answers: [Answer]
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []

    func on(_ method: String, _ suffix: String, _ answers: Answer...) {
        on(method, suffix, answers: answers)
    }

    /// The same, for a script built rather than written out: ten refusals and then the machine back.
    func on(_ method: String, _ suffix: String, answers: [Answer]) {
        lock.withLock { routes.append(Route(method: method, suffix: suffix, answers: answers)) }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func requests(to suffix: String) -> [URLRequest] {
        requests.filter { $0.url?.path().hasSuffix(suffix) == true }
    }

    private func next(for request: URLRequest) -> Answer {
        lock.withLock {
            recorded.append(request)
            let path = request.url?.path() ?? ""
            guard let index = routes.firstIndex(where: { $0.method == (request.httpMethod ?? "GET") && path.hasSuffix($0.suffix) }) else {
                return Answer(status: 404, body: Data(#"{"code":"not_found","message":"No fake route."}"#.utf8))
            }
            // The last answer of a route repeats for every later request.
            if routes[index].answers.count > 1 { return routes[index].answers.removeFirst() }
            return routes[index].answers[0]
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = next(for: request)
        if let failure = answer.failure { throw failure }
        return (answer.body, HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!)
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let answer = next(for: request)
        if let failure = answer.failure { throw failure }
        let lines = answer.lines ?? String(decoding: answer.body, as: UTF8.self).components(separatedBy: "\n")
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return (HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!, stream)
    }
}

extension FakeTransport.Answer {
    static func json(_ text: String, status: Int = 200) -> Self {
        Self(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
    }

    static func noContent() -> Self { Self(status: 204, body: Data()) }

    static func dropped() -> Self { Self(status: 0, body: Data(), failure: URLError(.networkConnectionLost)) }
}

enum Fixtures {
    static let api = URL(string: "https://runbloom.test/api/v1")!
    static let machine = "https://bloom-01k5machine.sprites.test"

    static func api(_ transport: FakeTransport, tokens: TokenLog = TokenLog()) -> RunbloomAPI {
        RunbloomAPI(baseURL: api, transport: transport) { force in
            tokens.record(force)
            return force ? "fresh-access" : "access"
        }
    }

    static func sessionToken(_ token: String = "session-1", awake: Bool = true, expires: String = "2099-01-01T00:00:00.000000Z") -> String {
        """
        {"data": {"token": "\(token)", "expires_at": "\(expires)", "machine_url": "\(machine)", "awake": \(awake), "abilities": ["view", "prompt", "terminal", "files", "preview", "share"]}}
        """
    }
}

final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ force: Bool) { lock.withLock { values.append(force) } }
    var forced: [Bool] { lock.withLock { values } }
}

/// Every phase a connection reported, in order, collected off the stream so a test can assert
/// what it did NOT say as well as what it did.
final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WorkspaceConnection.Phase] = []
    func record(_ phase: WorkspaceConnection.Phase) { lock.withLock { values.append(phase) } }
    var phases: [WorkspaceConnection.Phase] { lock.withLock { values } }
}

/// Every wait a connection asks for, in the order it asked, and none of them taken.
///
/// **What a backoff can be tested on is what it asked for, not how long it took.** Waiting out the
/// real delays would put the wall clock in the assertion, where a busy machine can move it; the
/// durations themselves cannot be moved by anything except somebody editing the table.
final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    var asked: [Duration] { lock.withLock { values } }

    /// The sleep to hand a connection: records the duration and returns at once.
    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            lock.withLock { values.append(duration) }
            await Task.yield()
        }
    }

    /// In seconds, with the two the notices are held for taken out.
    ///
    /// `WorkspaceConnection` holds the waking notice for half a second and the retrying notice for
    /// two, from tasks that race the loop, so a recorded 0.5 cannot be told from a retry of 0.5 and
    /// a recorded 2 cannot be told from a retry of 2. Those two values are dropped rather than
    /// guessed at, which leaves a sequence that is the backoff table and nothing else.
    var backoffSeconds: [Double] {
        asked.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
            .filter { $0 != 0.5 && $0 != 2 }
    }
}

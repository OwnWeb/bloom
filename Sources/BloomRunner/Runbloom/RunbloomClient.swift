import AsyncHTTPClient
import BloomCore
import Foundation
import NIOCore
import NIOHTTP1

/// Bloom Runner's calls to runbloom.app's machine API, each authorised by the workspace secret.
///
/// Only the transport and the contract live here: the paths, the bodies, what each answer decodes
/// to and which failure it is. What to do about a failure (retry a report, block a prompt, pause
/// the queue) belongs to the callers, `ReportDelivery` and `RunbloomTurns`, which is why every
/// method throws a `RunbloomError` rather than deciding. See docs/REMOTE-WORKSPACES.md, "The
/// machine-facing endpoints on runbloom.app".
///
/// The `HTTPClient` is passed in rather than made here, because it owns an event loop and has to
/// be shut down by whoever owns the process, and one client is shared by every caller.
public struct RunbloomClient: Sendable {
    /// `{base}/api/machine/workspaces/{id}`, built once. Held as the path rather than the id so
    /// the id is never mistaken for one of Bloom's own.
    private let workspaceURL: String
    private let secret: WorkspaceSecret
    private let http: HTTPClient
    private let timeout: TimeAmount
    /// Nothing runbloom.app answers here is near this; it only bounds a misbehaving proxy.
    static let largestAnswer = 1 << 20

    /// Every call is small, and a queue or a flush before sleep waits on it, so a hung connection
    /// must not hold either for longer than `timeout`. A refused connection is retried by
    /// `HTTPClient` until then too, which is why a test passes something shorter.
    public init(baseURL: String, workspaceID: String, secret: String, http: HTTPClient, timeout: Duration = .seconds(15)) {
        self.init(baseURL: baseURL, workspaceID: workspaceID, secret: WorkspaceSecret(fixed: secret), http: http, timeout: timeout)
    }

    public init(baseURL: String, workspaceID: String, secret: WorkspaceSecret, http: HTTPClient, timeout: Duration = .seconds(15)) {
        let (seconds, attoseconds) = timeout.components
        self.timeout = .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        workspaceURL = "\(base)/api/machine/workspaces/\(workspaceID)"
        self.secret = secret
        self.http = http
    }

    public func postSummary(_ body: Data) async throws {
        _ = try await send(.POST, "/summary", body: body, expecting: [204])
    }

    public func postUsage(_ body: Data) async throws {
        _ = try await send(.POST, "/usage", body: body, expecting: [204])
    }

    /// Everybody with access to this workspace, for resolving and validating a mention.
    ///
    /// **A pull rather than a push, and refetching is just asking again.** A machine holding a list
    /// from three weeks ago refuses a colleague who joined last week, which is the same failure as
    /// refusing an id outright, only slower and harder to see. No addresses in it: see
    /// `WorkspaceMember`.
    public func members() async throws -> [WorkspaceMember] {
        struct Answer: Decodable { var members: [WorkspaceMember]? }
        let data = try await send(.GET, "/members", expecting: [200])
        return try decode(Answer.self, data, status: 200).members ?? []
    }

    /// Tells runbloom.app that somebody was addressed, so it can mail them if they were not here.
    ///
    /// **Its own call rather than folded into a report, because it causes mail.** Anything
    /// coalesced, retried for unrelated reasons or replayed would eventually send two emails or
    /// none. runbloom.app dedupes on the message id **per addressed person**, so a retry is free
    /// and a partial delivery cannot double-mail or lose somebody.
    ///
    /// **The id must never be reused for a different message**: a reused one is silently treated as
    /// a retry and nobody is mailed, which fails without a symptom. It is a ULID minted once when
    /// the row is written and kept on the row, so a retry after a restart sends the same one.
    public func reportAddressed(_ body: Data) async throws {
        _ = try await send(.POST, "/addressed", body: body, expecting: [200, 202, 204])
    }

    public func environment() async throws -> [String: String] {
        struct Answer: Decodable { var environment: [String: String]? }
        let data = try await send(.GET, "/environment", expecting: [200])
        return try decode(Answer.self, data, status: 200).environment ?? [:]
    }

    /// Registers a turn or a terminal session while the prompter's token is fresh, and answers
    /// runbloom.app's turn id. `chatID` and `agent` go as JSON null for a terminal, as the contract
    /// has them present either way.
    public func registerTurn(kind: RemoteTurnKind, chatID: String?, agent: AgentKind?, sessionToken: String) async throws -> String {
        struct Answer: Decodable {
            var turnID: String
            enum CodingKeys: String, CodingKey { case turnID = "turn_id" }
        }
        let body: [String: Any] = [
            "kind": kind.rawValue,
            "session_token": sessionToken,
            "chat_id": chatID ?? NSNull(),
            "agent": agent?.wireName ?? NSNull(),
        ]
        let data = try await send(.POST, "/turns", body: JSONSerialization.data(withJSONObject: body), expecting: [201, 200])
        return try decode(Answer.self, data, status: 201).turnID
    }

    public func startTurn(_ id: String) async throws -> RunbloomTurnStart {
        let data = try await send(.POST, "/turns/\(id)/start", expecting: [200])
        return try decode(RunbloomTurnStartBody.self, data, status: 200).start
    }

    /// Idempotent on runbloom.app, so a caller that is unsure whether an earlier attempt landed
    /// can simply send it again.
    public func endTurn(_ id: String) async throws {
        _ = try await send(.DELETE, "/turns/\(id)", expecting: [204, 200])
    }

    public func gitCredentials(repository: String, operation: RunbloomGitOperation, turnID: String?) async throws -> RunbloomGitCredential {
        let body: [String: Any] = [
            "repository": repository,
            "operation": operation.rawValue,
            "turn_id": turnID ?? NSNull(),
        ]
        let data = try await send(.POST, "/git-credentials", body: JSONSerialization.data(withJSONObject: body), expecting: [200])
        guard let credential = try decode(RunbloomGitCredentialBody.self, data, status: 200).credential else {
            throw RunbloomError.unexpected(status: 200)
        }
        return credential
    }

    // MARK: - Transport

    /// A call refused for its secret is sent once more when workspace.json now holds another one,
    /// because runbloom.app rotated it and the control call saying so has not arrived (or never
    /// will). Every call here is idempotent on runbloom.app or harmless to repeat, which is what
    /// makes sending it twice safe.
    private func send(_ method: HTTPMethod, _ path: String, body: Data? = nil, expecting success: Set<Int>) async throws -> Data {
        do {
            return try await sendOnce(method, path, body: body, expecting: success)
        } catch let error as RunbloomError where error.isTerminal && secret.reload() {
            return try await sendOnce(method, path, body: body, expecting: success)
        }
    }

    private func sendOnce(_ method: HTTPMethod, _ path: String, body: Data?, expecting success: Set<Int>) async throws -> Data {
        var request = HTTPClientRequest(url: workspaceURL + path)
        request.method = method
        request.headers.add(name: "Authorization", value: "Bearer \(secret.current)")
        request.headers.add(name: "Accept", value: "application/json")
        if let body {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: body))
        }

        let status: Int
        let answer: Data
        do {
            let response = try await http.execute(request, timeout: timeout)
            status = Int(response.status.code)
            let buffer = try await response.body.collect(upTo: Self.largestAnswer)
            answer = Data(buffer.readableBytesView)
        } catch {
            // AsyncHTTPClient reports a cancelled task as its own error, which would read as
            // runbloom.app being down to a caller that is only shutting down.
            if Task.isCancelled { throw CancellationError() }
            // The error's own description names the host and the failure, never a header.
            throw RunbloomError.unreachable(String(describing: error))
        }

        if success.contains(status) { return answer }
        if status >= 500 { throw RunbloomError.unreachable("runbloom.app answered \(status).") }
        throw Self.refusal(status: status, answer)
    }

    /// A 4xx with runbloom.app's `code` and `message` is a refusal; one without them (a proxy's
    /// page, a bare 401) is unexpected, because there is no sentence to show a person.
    static func refusal(status: Int, _ answer: Data) -> RunbloomError {
        struct Refusal: Decodable {
            var code: String
            var message: String
            var limit: String?
            var retryAfter: Int?
            enum CodingKeys: String, CodingKey {
                case code, message, limit
                case retryAfter = "retry_after"
            }
        }
        guard let refusal = try? JSONDecoder().decode(Refusal.self, from: answer) else {
            return .unexpected(status: status)
        }
        return .refused(status: status, code: refusal.code, message: refusal.message, limit: refusal.limit, retryAfter: refusal.retryAfter)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, status: Int) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RunbloomError.unexpected(status: status)
        }
    }
}

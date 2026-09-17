import Foundation

/// Anything runbloom.app's `/api/v1` refused, as it wrote it: `{"code", "message"}`, plus `limit`
/// and `retry_after` where they apply, and the HTTP status it came with.
///
/// The message is shown as runbloom.app wrote it. The code is what a client switches on, and the
/// few a client acts on differently are named below; every other code is a sentence to show.
public struct RunbloomRefusal: Error, Sendable, Hashable, Codable {
    public var status: Int
    public var code: String
    public var message: String
    public var limit: String?
    public var retryAfter: Int?

    public init(status: Int, code: String, message: String, limit: String? = nil, retryAfter: Int? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.limit = limit
        self.retryAfter = retryAfter
    }

    enum CodingKeys: String, CodingKey {
        case status, code, message, limit
        case retryAfter = "retry_after"
    }

    /// Reads a refusal body, or makes one out of a status when the body is not one: an HTML error
    /// page from a proxy, or nothing at all.
    public static func from(status: Int, body: Data) -> RunbloomRefusal {
        struct Body: Decodable {
            var code: String?
            var message: String?
            var limit: String?
            var retryAfter: Int?

            enum CodingKeys: String, CodingKey {
                case code, message, limit
                case retryAfter = "retry_after"
            }
        }
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        let code = decoded?.code ?? Self.code(forStatus: status)
        let message = decoded?.message.flatMap { $0.isEmpty ? nil : $0 } ?? Self.message(forStatus: status)
        return RunbloomRefusal(status: status, code: code, message: message, limit: decoded?.limit, retryAfter: decoded?.retryAfter)
    }

    private static func code(forStatus status: Int) -> String {
        switch status {
        case 401: "unauthenticated"
        case 403: "forbidden"
        case 404: "not_found"
        case 409: "conflict"
        case 422: "validation_failed"
        case 429: "too_many_requests"
        default: "server_error"
        }
    }

    private static func message(forStatus status: Int) -> String {
        switch status {
        case 401: "Sign in to your Bloom account again."
        case 403: "Your Bloom account cannot do that."
        case 404: "That Cloud workspace is no longer there."
        case 429: "runbloom.app is busy. Try again in a moment."
        default: "runbloom.app could not answer (HTTP \(status)). Try again in a moment."
        }
    }

    /// The access token was refused: the account was signed out elsewhere, or its refresh token ran
    /// out. The app goes to its signed out state rather than showing this as a failure.
    public var isUnauthenticated: Bool { status == 401 || code == "unauthenticated" }

    /// The machine is still being created or bootstrapped, or failed and is being replaced. Asking
    /// again after `retry_after` is the whole of what a client does.
    public var isMachineNotReady: Bool { code == "machine_not_ready" }

    public var isArchived: Bool { code == "workspace_archived" }

    /// A team limit. See `LimitNotice` for how it reads.
    public var isLimit: Bool { code == "limit_reached" }
}

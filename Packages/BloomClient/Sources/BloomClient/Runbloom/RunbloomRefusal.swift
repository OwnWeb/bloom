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
    /// Why a wait is long, where runbloom.app knows: a `machine_not_ready` whose create the
    /// provider turned away says so here. Drawn under the step being waited on, never in place
    /// of `message`.
    public var detail: String?

    public init(
        status: Int, code: String, message: String, limit: String? = nil, retryAfter: Int? = nil, detail: String? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.limit = limit
        self.retryAfter = retryAfter
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case status, code, message, limit, detail
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
            var detail: String?

            enum CodingKeys: String, CodingKey {
                case code, message, limit, detail
                case retryAfter = "retry_after"
            }
        }
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        let code = decoded?.code ?? Self.code(forStatus: status)
        let message = decoded?.message.flatMap { $0.isEmpty ? nil : $0 } ?? Self.message(forStatus: status)
        let detail = decoded?.detail.flatMap { $0.isEmpty ? nil : $0 }
        return RunbloomRefusal(
            status: status, code: code, message: message, limit: decoded?.limit, retryAfter: decoded?.retryAfter, detail: detail
        )
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
        case 404: "That Bloom Cloud workspace is no longer there."
        case 429: "runbloom.app is busy. Try again in a moment."
        default: "runbloom.app could not answer (HTTP \(status)). Try again in a moment."
        }
    }

    /// The access token was refused: the account was signed out elsewhere, or its refresh token ran
    /// out. The app goes to its signed out state rather than showing this as a failure.
    public var isUnauthenticated: Bool { status == 401 || code == "unauthenticated" }

    /// The machine is being created or bootstrapped, or a workspace being moved is pointing at a
    /// new one. Asking again after `retry_after` is the whole of what a client does.
    ///
    /// **The progress case, and only that.** A machine whose build failed and one that is being
    /// deleted are their own codes and carry no `retry_after`, which is what tells them apart from
    /// this one: see `WorkspaceConnection.Phase.unavailable`. A machine that is asleep never
    /// reaches any of them, because being asleep has nothing to do with being ready.
    public var isMachineNotReady: Bool { code == "machine_not_ready" }

    /// runbloom.app is telling the machine the workspace became shared, which takes a moment and is
    /// refused to everybody but the owner meanwhile. Waited out like a machine that is not ready.
    public var isSharingInProgress: Bool { code == "sharing_in_progress" }

    public var isArchived: Bool { code == "workspace_archived" }

    /// A team limit. See `LimitNotice` for how it reads.
    public var isLimit: Bool { code == "limit_reached" }
}

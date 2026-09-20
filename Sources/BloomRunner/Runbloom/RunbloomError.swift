import Foundation

/// Why a call to runbloom.app did not return what was asked for.
///
/// Three cases because the callers act on three different things. A refusal is runbloom.app
/// saying no on purpose, with a code to switch on and a sentence to show, and is never worth
/// retrying. `unreachable` is the network or runbloom.app itself failing (a 5xx included), which
/// is. `unexpected` is an answer outside the contract, kept apart so it is not mistaken for either.
///
/// No case carries a header, a request body or a response body other than runbloom.app's own
/// `code` and `message`, so the workspace secret, an agent key or a GitHub token cannot end up in
/// a log line or a queue's pause message by way of an error description.
public enum RunbloomError: Error, LocalizedError, Sendable, Hashable, CustomStringConvertible {
    case refused(status: Int, code: String, message: String, limit: String?, retryAfter: Int?)
    case unreachable(String)
    case unexpected(status: Int)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .refused(_, _, let message, _, _): message
        case .unreachable(let reason): "runbloom.app could not be reached: \(reason)"
        case .unexpected(let status): "runbloom.app answered with an unexpected status \(status)."
        }
    }

    /// Whether sending the same request again later could succeed. A 4xx is runbloom.app's
    /// considered answer about this request, except 408 and 429, which are about timing.
    /// runbloom.app no longer recognises this machine: a wrong secret, or a workspace that is gone
    /// or archived. Nothing sent afterwards can succeed.
    public var isTerminal: Bool {
        if case .refused(401, "invalid_workspace_secret", _, _, _) = self { return true }
        return false
    }

    /// runbloom.app answered and asked for the report later: too many at once, or a timeout on its
    /// own side. **Retried like a failure and recorded like a success**, because the one thing this
    /// proves is that the machine can reach it.
    public var isBackpressure: Bool {
        switch self {
        case .unreachable: false
        case .refused(let status, _, _, _, _), .unexpected(let status): status == 408 || status == 429
        }
    }

    public var isWorthRetrying: Bool {
        switch self {
        case .unreachable: true
        case .refused(let status, _, _, _, _), .unexpected(let status):
            !(400..<500).contains(status) || status == 408 || status == 429
        }
    }
}

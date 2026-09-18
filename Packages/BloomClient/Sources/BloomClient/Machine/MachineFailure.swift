import BloomProtocol
import Foundation

/// Why talking to a Cloud workspace's machine did not work, in the terms a client acts on.
///
/// A command the machine answered with an error is not one of these: it is a `WireError` in the
/// reply, recorded against its command id like any other answer. These are the failures before an
/// answer, and the difference matters, because only these leave the outcome unknown.
public enum MachineFailure: Error, Sendable, Hashable {
    /// The token was refused (HTTP 401). A fresh one is fetched and the request tried once more;
    /// a second refusal means access went away.
    case unauthenticated(WireError)
    /// The request never got an answer: a timeout, a dropped connection, a machine that paused
    /// mid-request. Whether a mutation ran is unknown, so it is retried under the same command id.
    case noAnswer(String)
    /// An HTTP error with a failure body: too large, not an envelope.
    case refused(status: Int, error: WireError)
    /// An answer this client cannot read.
    case unreadable(String)

    public var message: String {
        switch self {
        case .unauthenticated(let error): error.message
        case .noAnswer(let detail): "The Bloom Cloud workspace did not answer. \(detail)"
        case .refused(_, let error): error.message
        case .unreadable(let detail): "The Bloom Cloud workspace answered in a way this version of Bloom cannot read. \(detail)"
        }
    }
}

extension WireError {
    /// A code this client does not know is treated as `internal`, as the protocol asks. The
    /// message is kept, because it is still the best sentence available.
    public var knownCode: WireErrorCode {
        let known: Set<WireErrorCode> = [
            .invalidRequest, .unsupportedVersion, .unauthenticated, .missingAbility, .tokenExpired, .notFound, .conflict,
            .commandIDReused, .outcomeUnknown, .busy, .workspaceChanging, .alreadyAnswered, .invalidValue, .tooLarge,
            .agentUnavailable, .gitFailed, .limitReached, .unavailable, .internal,
        ]
        return known.contains(code) ? code : .internal
    }
}

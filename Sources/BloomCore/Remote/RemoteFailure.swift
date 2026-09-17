import BloomProtocol
import Foundation

/// A refusal from the Cloud workspace runtime, with the stable code a client switches on.
///
/// Everything the runtime refuses on purpose throws one of these. Anything else that escapes (a
/// git failure, a SQLite error) reaches the client as `internal` with its own description, which
/// is honest about being unplanned. See `WireError`.
public struct RemoteFailure: Error, LocalizedError, Sendable, Hashable {
    public var code: WireErrorCode
    public var message: String

    public init(_ code: WireErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public var wire: WireError { WireError(code, message) }

    /// Any error as the client will read it.
    public static func wire(_ error: any Error) -> WireError {
        if let failure = error as? RemoteFailure { return failure.wire }
        if error is CancellationError { return WireError(.unavailable, "The server stopped this command before it finished.") }
        if let shell = error as? ShellError { return WireError(.gitFailed, shell.description) }
        return WireError(.internal, error.localizedDescription)
    }

    static func invalid(_ message: String) -> Self { Self(.invalidValue, message) }
    static func notFound(_ message: String) -> Self { Self(.notFound, message) }
    static let shuttingDown = Self(.unavailable, "The server is shutting down.")
}

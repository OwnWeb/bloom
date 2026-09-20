import Foundation

/// A failure as a reader in another language can act on it: a stable code to switch on, and a
/// sentence to show a person.
///
/// #163 sent failures as prose, so the only way a client could tell "this workspace is being
/// archived" from "the prompt is too large" was to compare English. The code is the contract; the
/// message is free to be reworded.
public struct WireError: Codable, Sendable, Hashable, Error {
    public var code: WireErrorCode
    public var message: String

    public init(_ code: WireErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// Stable failure codes. A new one is added, never renamed, and a client treats one it does not
/// know as `internal`.
public struct WireErrorCode: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: any Decoder) throws { rawValue = try String(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try rawValue.encode(to: encoder) }

    /// The body was not a version 1 envelope, or an operation's fields were missing or wrong.
    public static let invalidRequest: Self = "invalid_request"
    /// The envelope named a protocol or version this server does not speak.
    public static let unsupportedVersion: Self = "unsupported_version"
    /// No token, a token that did not verify, or one for another workspace.
    public static let unauthenticated: Self = "unauthenticated"
    /// The token verified but does not carry the ability this operation needs.
    public static let missingAbility: Self = "missing_ability"
    /// The token's lifetime ended while a stream was open.
    public static let tokenExpired: Self = "token_expired"
    /// A chat, a queued prompt, a question or a file that is not there.
    public static let notFound: Self = "not_found"
    /// A revision check failed: the file, the settings or the preview moved since it was read.
    public static let conflict: Self = "conflict"
    /// The same command id was sent with a different operation.
    public static let commandIDReused: Self = "command_id_reused"
    /// The server stopped while this command was running, so whether it happened is not known.
    public static let outcomeUnknown: Self = "outcome_unknown"
    /// The chat is running a turn, or stopping one, and cannot take this now.
    public static let busy: Self = "busy"
    /// The workspace is being set up or archived.
    public static let workspaceChanging: Self = "workspace_changing"
    /// Somebody else answered this question first.
    public static let alreadyAnswered: Self = "already_answered"
    /// A value outside what this operation accepts: an empty prompt, a path outside the worktree.
    public static let invalidValue: Self = "invalid_value"
    /// A body, a file or a prompt larger than this operation takes.
    public static let tooLarge: Self = "too_large"
    /// The agent this chat runs is not installed on this machine.
    public static let agentUnavailable: Self = "agent_unavailable"
    /// A git or GitHub command failed; the message carries what it said.
    public static let gitFailed: Self = "git_failed"
    /// runbloom.app refused to start a turn because a team limit was reached.
    public static let limitReached: Self = "limit_reached"
    /// The server is shutting down or going to sleep.
    public static let unavailable: Self = "unavailable"
    /// Anything else. The message says what.
    public static let `internal`: Self = "internal"
}

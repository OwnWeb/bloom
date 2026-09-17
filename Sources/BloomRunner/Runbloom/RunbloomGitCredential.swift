import Foundation

/// What a GitHub token is being asked for. `write` is refused by runbloom.app outside a turn, so
/// setup and resume can only ever read.
public enum RunbloomGitOperation: String, Sendable, Hashable {
    case read
    case write
}

/// A short-lived GitHub token from `POST .../git-credentials`, for git's credential helper and the
/// `gh` wrapper. Never written to disk.
public struct RunbloomGitCredential: Sendable, Hashable, CustomStringConvertible {
    public var token: String
    public var expiresAt: Date
    public var username: String

    public init(token: String, expiresAt: Date, username: String) {
        self.token = token
        self.expiresAt = expiresAt
        self.username = username
    }

    /// Without the token, for the same reason as `RunbloomTurnStart`.
    public var description: String { "RunbloomGitCredential(username: \(username), expiresAt: \(expiresAt))" }
}

struct RunbloomGitCredentialBody: Decodable {
    var token: String
    var expiresAt: String
    var username: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case username
    }

    var credential: RunbloomGitCredential? {
        guard let date = Self.date(expiresAt) else { return nil }
        return RunbloomGitCredential(token: token, expiresAt: date, username: username)
    }

    /// Laravel writes microseconds (`2026-09-17T10:00:00.000000Z`), which neither ISO 8601 style
    /// in Foundation reads on both platforms, so the fraction is taken off and added back by hand.
    static func date(_ text: String) -> Date? {
        let plain = Date.ISO8601FormatStyle()
        guard let dot = text.firstIndex(of: ".") else { return try? plain.parse(text) }
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let whole = String(text[..<dot]) + String(text[digits.endIndex...])
        guard let seconds = try? plain.parse(whole) else { return nil }
        let fraction = Double("0." + digits) ?? 0
        return seconds.addingTimeInterval(fraction)
    }
}

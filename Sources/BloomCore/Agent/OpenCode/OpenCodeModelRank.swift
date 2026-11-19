import Foundation

/// Whether a model id is one of OpenCode's, so a stored one opens OpenCode without a fetch.
///
/// OpenCode names every model `provider/model` (`ollama/qwen3.5:4b`, `anthropic/claude-…`), and no
/// other backend's ids contain a slash. The one exception Bloom knows is a Bedrock ARN handed to
/// Claude Code, which is why `arn:` is ruled out first.
public enum OpenCodeModelRank {
    /// Whether `opencode` is on the PATH, asked each time: `Shell.which` caches what it finds and
    /// looks again for what it did not, so an install or the login shell's PATH arriving late is
    /// seen on the next call.
    ///
    /// A slash is only read as OpenCode's when OpenCode can run it: a repository's
    /// `models.default` or a bridge call naming `openai/…` for another CLI would otherwise open a
    /// chat that cannot start. The ceiling: an executable set only as a custom path in Settings,
    /// off the PATH, is not seen here, so such an id needs `opencode:` in front of it or
    /// discovery's own list, which `ModelIdentifier.resolve` reads first.
    public static var isInstalled: Bool { Shell.which(AgentKind.openCode.executableName) != nil }

    public static func recognises(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.lowercased().hasPrefix("arn:") else { return false }
        let parts = id.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }
}

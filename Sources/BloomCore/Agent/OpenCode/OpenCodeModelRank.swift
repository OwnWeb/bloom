import Foundation

/// Whether a model id is one of OpenCode's, so a stored one opens OpenCode without a fetch.
///
/// OpenCode names every model `provider/model` (`ollama/qwen3.5:4b`, `anthropic/claude-…`), and no
/// other backend's ids contain a slash. The one exception Bloom knows is a Bedrock ARN handed to
/// Claude Code, which is why `arn:` is ruled out first.
public enum OpenCodeModelRank {
    /// Whether `opencode` is on the PATH, looked up once per launch.
    ///
    /// A slash is only read as OpenCode's when OpenCode can run it: a repository's
    /// `models.default` or a bridge call naming `openai/…` for another CLI would otherwise open a
    /// chat that cannot start. The ceiling: a custom executable path set in Settings, or an
    /// install made while Bloom runs, is not seen until the next launch. Discovery's own list
    /// still recognises its ids exactly, see `ModelIdentifier.resolve`.
    public static let isInstalled = Shell.which(AgentKind.openCode.executableName) != nil

    public static func recognises(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.lowercased().hasPrefix("arn:") else { return false }
        let parts = id.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }
}

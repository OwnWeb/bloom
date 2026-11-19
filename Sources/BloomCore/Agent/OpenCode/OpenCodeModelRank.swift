import Foundation

/// Whether a model id is one of OpenCode's, so a stored one opens OpenCode without a fetch.
///
/// OpenCode names every model `provider/model` (`ollama/qwen3.5:4b`, `anthropic/claude-…`), and no
/// other backend's ids contain a slash. The one exception Bloom knows is a Bedrock ARN handed to
/// Claude Code, which is why `arn:` is ruled out first.
public enum OpenCodeModelRank {
    public static func recognises(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.lowercased().hasPrefix("arn:") else { return false }
        let parts = id.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }
}

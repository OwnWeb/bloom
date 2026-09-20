import BloomProtocol
import Foundation

/// The project's quick prompts as `quick_prompts` answers them, read off the checkout.
///
/// **The Mac's loader, not a second one.** `SettingsLoader` already reads `[[quick_prompts]]`,
/// refuses `send_immediately`, resolves the symbol and refuses a duplicate name, and a web menu
/// that disagreed with the Mac's about which prompts a file offers would be two readings of one
/// file. What this adds is only what the wire needs: paths made relative to the worktree, since
/// an absolute path on a machine means nothing to a client, and the issues narrowed to the ones
/// about quick prompts.
///
/// **Only the repository's files**, which is already the loader's rule for quick prompts: it
/// applies them from `repoPaths` and never from a home file. The issues are held to the same
/// line, so a broken `~/.bloom/settings.toml` baked into the machine's image is not reported to
/// somebody as a problem with their project.
enum RemoteQuickPrompts {
    static func answer(repo: String) -> OperationResult {
        answer(SettingsLoader.load(repo: repo), repo: repo)
    }

    static func answer(_ settings: RepoSettings, repo: String) -> OperationResult {
        let projectFiles = Set(SettingsLoader.repoPaths(repo: repo))
        let prompts = settings.quickPrompts.map {
            QuickPromptRecord(id: $0.id, name: $0.name, prompt: $0.text, symbol: $0.symbol,
                              isNewChat: $0.opensNewChat, source: relative($0.source, to: repo))
        }
        let issues = settings.issues
            .filter { projectFiles.contains($0.path) && isAboutQuickPrompts($0) }
            .map { SettingsIssueRecord(source: relative($0.path, to: repo), message: $0.message, line: $0.line) }
        return .quickPrompts(prompts: prompts, issues: issues)
    }

    /// A prompt's own issue, the whole `quick_prompts` key refused, or a file that would not parse
    /// and so took its prompts with it. Named rather than "every `.file` issue but one", because
    /// the next section to gain a whole-file sentence would otherwise arrive in a quick prompt menu
    /// that has no business explaining it; "Run scripts were skipped" is already one.
    static func isAboutQuickPrompts(_ issue: SettingsIssue) -> Bool {
        switch issue.entry {
        case .quickPrompt: true
        case .file: issue.message.hasPrefix("Quick prompts were skipped") || issue.message.hasPrefix("This file was skipped")
        case .runScript: false
        }
    }

    static func relative(_ path: String, to repo: String) -> String {
        let root = repo.hasSuffix("/") ? repo : repo + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}

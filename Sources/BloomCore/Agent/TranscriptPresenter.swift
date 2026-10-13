import Foundation

/// Which presenter draws a call. Mac, web and future clients get the same readable row.
public enum TranscriptPresenter {
    public static func present(_ use: AgentToolUse, worktree: String = "") -> ToolPresentation {
        CodexItemPresenter.present(use, worktree: worktree) ?? ToolPresenter.present(use, worktree: worktree)
    }

    public static func present(name: String, input: JSONValue, worktree: String = "") -> ToolPresentation {
        if let item = CodexTranslation.item(in: input) {
            return CodexItemPresenter.present(item, worktree: worktree)
        }
        return ToolPresenter.present(name: name, input: input, worktree: worktree)
    }
}

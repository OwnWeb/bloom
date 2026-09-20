import BloomProtocol
import Foundation

// Continuing in the same workspace after its pull request merged, as the Mac's merged strip does:
// a new branch cut from the base in this worktree, and the agent told in the chat it was working in.
extension WorkspaceRuntime {
    /// **The Mac's own pieces, not a second version of them.** `ContinuationGate` decides and is
    /// the only thing allowed to say yes, `WorkspaceManager.continueOnNewBranch` does the git work
    /// and moves the row, and the prompt is the registry's `continueAfterMerge` in its built-in
    /// wording, since a machine has no Settings screen to have changed it. What is here is only
    /// what the Mac reads off its window: the pull request, from `gh` on this machine, and whether
    /// an agent is working.
    ///
    /// **The session is not restarted**, for the reason the Mac's comment gives: a new one would
    /// know nothing. The prompt goes in as the person who asked, through the queue like any other,
    /// so runbloom.app registers the turn under them. The new branch reaches runbloom.app in the
    /// next summary, which carries the row's branch.
    func continueAfterMerge(chatID: String?, as caller: RemoteCaller) async throws -> OperationResult {
        // It moves the branch and it prompts the agent, so it needs both.
        try caller.requires("prompt")
        let workspace = try await workspace()
        let checkedOut = try? await Git.currentBranch(of: workspace.path)
        var pull = try? await GitHub.pullRequest(forBranch: workspace.branch, worktree: workspace.path, maxAge: .seconds(30))
        if pull == nil, let checkedOut, checkedOut != workspace.branch {
            pull = try? await GitHub.pullRequest(forBranch: checkedOut, worktree: workspace.path, maxAge: .seconds(30))
        }
        var agentRunning = false
        for session in sessions.values where await session.isBusy { agentRunning = true }

        let manager = WorkspaceManager(store: store)
        let facts = try await manager.continuationFacts(workspace: workspace, pullRequest: pull, isAgentRunning: agentRunning)
        let branch: String
        switch ContinuationGate.decide(facts) {
        case .refuse(let refusal): throw RemoteFailure(.conflict, refusal.sentence)
        case .cut(let cut): branch = cut
        }
        let continuation = try await manager.continueOnNewBranch(workspace: workspace, branch: branch)

        let template = PromptRegistry.definition(for: .continueAfterMerge).defaultTemplate
        let prompt = continuation.render(template: template, pullRequest: pull?.number ?? 0).text
        let chat = try await continuationChat(chatID, as: caller)
        _ = try await send(chat, text: prompt, audience: nil, as: caller)
        return .text(branch)
    }

    /// The chat to tell: the one named, else the most recent open chat a person started, else a
    /// new one, as the Mac falls back to a new "Continue" chat.
    private func continuationChat(_ chatID: String?, as caller: RemoteCaller) async throws -> String {
        if let chatID, !chatID.isEmpty { return chatID }
        let open = try await store.sessions(workspaceID: workspaceID)
            .filter { $0.archivedAt == nil && $0.parentSessionID == nil }
        if let recent = open.max(by: { $0.updatedAt < $1.updatedAt }) { return recent.id.rawValue }
        return try await newChat(try await newChatControls().record, as: caller).id
    }
}

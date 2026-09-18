import AppKit
import BloomClient
import Foundation
import SwiftUI
import BloomCore
import BloomProtocol

/// What GitHub says about a Cloud workspace's branch, and what can be done about it.
///
/// Read from runbloom.app rather than from this Mac's `gh`, which has no access to the
/// repository: see `CloudPullRequestReader`. Merging and marking ready happen there too, as the
/// signed-in person; everything else composes a turn for the agent, which is what a local
/// workspace does with the same buttons.
extension CloudWorkspaceSession {
    // MARK: What GitHub thinks of it

    /// What GitHub says about the branch, as runbloom.app last read it: the whole of what the band
    /// draws, checks and merge blockers included.
    ///
    /// **One source.** There used to be a fallback to the workspace record's `pull_request`, on the
    /// argument that the machine's own `gh` reported one and it arrived with the workspace before
    /// runbloom.app had answered. **No machine ever filled that field**, so the fallback never had a
    /// value and its argument described a record that was never sent. The band is empty for the
    /// few seconds before runbloom.app answers, which is the honest state: nothing is known yet.
    var pullRequest: PullRequest? {
        guard let read = github.state else { return nil }
        return PullRequest(cloudState: read)
    }

    /// Whether this branch is known to have anything on it, which is what decides between "Target
    /// main" and "Nothing has changed on this branch yet" above the file list.
    ///
    /// **Two witnesses, because one of them can be stale and the other cannot see uncommitted
    /// work.** The file list is what the machine answered when it was last asked, and runbloom.app
    /// polls a summary carrying the same diff stat a local workspace reads off its own disk. The
    /// local surface says `!changedFiles.isEmpty || workspace.hasDiff` for exactly this reason, and
    /// this is that sentence with the Cloud half of each: an empty list that has not been refreshed
    /// since before the agent wrote a file said "nothing has changed" over a summary that said one
    /// file had.
    var hasKnownChanges: Bool {
        if !changedFiles.isEmpty { return true }
        return (cloud.item(id)?.summary?.diff?.files ?? 0) > 0
    }

    /// From runbloom.app, which asks GitHub with its own App rather than with this Mac's `gh`.
    /// Nil when it could not be asked at all.
    func readChecks() async -> [CheckRun]? {
        guard let read = await github.readChecks() else { return nil }
        return read.checks.map(CheckRun.init(cloudCheck:))
    }

    /// runbloom.app refreshes on a schedule, so the answer is up to a minute old and says so.
    var checksNote: String? {
        CloudChecksWording.freshness(fetchedAt: github.checks?.fetchedAt, isStale: github.checks?.stale ?? false)
    }

    var canSendCheckFailure: Bool { selectedChatID != nil || !chatIDs.isEmpty }

    /// The sentence goes to the chat in front. The log itself is not fetched here: `gh` on this Mac
    /// has no access to the repository a Cloud workspace's branch is in, and the agent on the
    /// machine does, so it is better placed to read the run than this Mac is.
    func sendCheckFailure(_ run: CheckRun) async -> String? {
        let where_ = run.detailsURL.map { " Its run is at \($0)." } ?? ""
        return await ask("The check \(run.name) failed on this branch.\(where_) Find out why and fix it.")
    }

    /// Never in the dark: the machine asks GitHub with the workspace's own credentials, so what
    /// this Mac's `gh` is doing has no bearing on what the strip may say.
    var gitHubReadiness: GitHubAvailability.State { .ready }

    var continueBlocker: String? {
        "Carrying on in a new branch is not built for a Bloom Cloud workspace yet. Make another Bloom Cloud workspace from the same project."
    }

    func continueAfterMerge(_ pullRequest: PullRequest) async -> AppModel.ContinuationOutcome {
        .failed(continueBlocker ?? "")
    }

    /// The Cloud archive, which asks the machine what is about to be lost and says that the
    /// conversation is deleted. See `CloudArchiveSheet`.
    func requestArchive(presenting: @escaping (ArchiveRequest) -> Void) async {
        cloud.archiving = id
    }

    func confirmArchive(_ request: ArchiveRequest, presenting: @escaping (ArchiveRequest) -> Void) async {}
    var isLoadingPullRequest: Bool { github.isLoading }
    /// Kept, where it used to be thrown away. The strip writes a notice when a merge is refused or
    /// a prompt cannot be sent, and a setter that did nothing meant a Cloud workspace's refusals
    /// vanished without a word.
    var pullRequestNotice: PullRequestNotice? {
        get { github.notice }
        set { github.notice = newValue }
    }
    var pullRequestRefreshFailure: GitHubReadFailure? { github.visibleFailure }
    func dismissPullRequestRefreshFailure() { github.dismissFailure() }

    func refreshPullRequest(maxAge: Duration) async {
        await github.refresh(maxAge: maxAge)
    }
    var localWork: LocalWork? { nil }
    var continued: ContinuedBranch? { nil }
    var mergeMethod: GitHub.MergeMethod { github.method }
    /// Nothing to read: the choice is remembered on this Mac and the methods the repository allows
    /// come with the pull request itself.
    func loadMergeMethod() async {}
    func chooseMergeMethod(_ method: GitHub.MergeMethod) async { github.choose(method) }

    /// Composing a turn for the agent is the same act in both kinds of workspace, and the machine
    /// can push and open a pull request itself, so these send the prompt to the chat in front.
    func requestPullRequest(overrides: PromptOverrides) async -> String? {
        await ask("Open a pull request for this branch.")
    }

    func requestPush(overrides: PromptOverrides) async -> String? {
        await ask("Push this branch.")
    }

    /// Merged by runbloom.app as the signed-in person rather than by the agent, which is the one
    /// place a Cloud workspace acts on GitHub itself: the merge is this person's, made with their
    /// access, and the head commit goes with the request so a branch that moved is refused.
    func requestMerge(_ pullRequest: PullRequest, method: GitHub.MergeMethod, overrides: PromptOverrides) async -> String? {
        await github.merge(method)
    }

    func requestFixConflicts(_ pullRequest: PullRequest, overrides: PromptOverrides) async -> String? {
        await ask("This branch conflicts with \(surfaceBaseBranch). Fix the merge conflicts.")
    }

    func markReadyForReview(_ pullRequest: PullRequest) async throws {
        if let refusal = await github.markReady() { throw CloudReviewFailure(message: refusal) }
    }

    var openInRepoID: RepoID? { nil }

    /// Sends a sentence to the chat in front, which is how every one of these acts on a Cloud
    /// workspace: the machine has the worktree and the git credentials, the Mac has neither.
    private func ask(_ sentence: String) async -> String? {
        guard let chatID = selectedChatID ?? chatIDs.first else {
            return "Open a chat in this Bloom Cloud workspace first."
        }
        return await send(sentence, chatID: chatID).sentence
    }
}

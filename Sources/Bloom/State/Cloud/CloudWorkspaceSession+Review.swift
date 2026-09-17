import BloomClient
import Foundation
import SwiftUI
import BloomCore
import BloomProtocol

/// A Cloud workspace as the shared review views see it: the same protocol `WorkspaceModel` answers
/// out of a worktree, answered here out of the machine.
///
/// The reads are the ones already built for the Changes pane (`CloudChanges`, which keeps the
/// snapshot and the patch cache so nothing is read twice), plus the whole file list, which is the
/// `files` operation. What is not here is what a Cloud workspace cannot do yet; those are
/// `capabilities`, and the views ask before they offer.
extension CloudWorkspaceSession: WorkspaceReviewSurface {
    var surfaceID: WorkspaceSurfaceID { .cloud(id) }

    var surfaceName: String {
        state.workspace?.name ?? cloud.item(id)?.displayName ?? "Cloud workspace"
    }

    var surfaceBranch: String {
        state.workspace?.branch ?? cloud.item(id)?.displayBranch ?? ""
    }

    var surfaceBaseBranch: String {
        state.workspace?.baseBranch ?? cloud.item(id)?.baseBranch ?? "main"
    }

    /// Nil, and every capability that would have read it is already false.
    var worktreePath: String? { nil }

    var capabilities: WorkspaceCapabilities {
        .cloud(
            // Each of these turns on here the day its half lands on the other side of the wire.
            history: true,
            revertChanges: false,
            searchTranscripts: false,
            preview: allows("preview"),
            terminal: allows("terminal"),
            managePullRequest: false
        )
    }

    var isRunning: Bool {
        state.chats.values.contains { $0.isRunning }
    }

    // MARK: What changed

    var diffScope: BloomCore.DiffScope { changes.localScope }

    func setDiffScope(_ scope: BloomCore.DiffScope) {
        changes.setScope(scope)
    }

    var scopeNote: String? { changes.scopeNote }

    var changedFiles: [ChangedFile] { changes.files.map(ChangedFile.init(cloudRecord:)) }

    var changesError: String? { changes.problem }

    var hasReadChanges: Bool { changes.hasRead }

    var isLoadingChanges: Bool { changes.isLoading }

    var changesGeneration: Int { changes.generation }

    func refreshChanges(_ reason: ChangesRefresh) async {
        await changes.refresh(quietly: reason == .quiet)
        // The commits move when the review does, and only while somebody is looking at them: a
        // machine trying to sleep should not be asked for a list nothing is drawing.
        if changes.inspectorTab == .history { await history.refresh() }
    }

    func readPatch(for file: ChangedFile) async throws -> String {
        try await changes.patch(for: file.path)
    }

    /// The same as a local workspace: the file opens in the review, which is a tab of this
    /// workspace's own strip.
    func openFile(path: String, focusing: Bool) {
        changes.selectedPath = path
        open(.changes)
    }

    var selectedFilePath: String? {
        get { changes.selectedPath }
        set { changes.selectedPath = newValue }
    }

    var selectedChangeLayer: ChangeLayer? {
        get { changes.selectedLayer }
        set { changes.selectedLayer = newValue }
    }

    /// The row identity the list highlights, which is the path with its layer where there is one.
    var selectedChangeID: String? {
        changedFiles.first { $0.path == changes.selectedPath && $0.layer == changes.selectedLayer }?.id
            ?? changedFiles.first { $0.path == changes.selectedPath }?.id
    }

    /// The review is one tab of this workspace's own strip and shows the selected file, so the two
    /// are the same thing here.
    var activeReviewPath: String? { changes.selectedPath }

    // MARK: The inspector's own state

    /// Setting it does what the local model's does: History lands on a commit rather than on the
    /// sentence asking for one, and leaving History puts the review back on the whole branch.
    var inspectorTab: InspectorTab {
        get { changes.inspectorTab }
        set {
            changes.inspectorTab = newValue
            switch newValue {
            case .history:
                Task {
                    await history.refresh()
                    guard changes.inspectorTab == .history, !diffScope.isHistorical,
                          let commit = history.commits.commits.first else { return }
                    setDiffScope(.commit(commit))
                }
            case .changes where diffScope.isHistorical:
                setDiffScope(.all)
            default:
                break
            }
        }
    }

    var availableInspectorTabs: [InspectorTab] {
        // No pull request to report on yet, so no Checks tab. It appears the day runbloom.app can
        // answer for one, by the same rule a local workspace's does.
        InspectorTab.available(for: nil)
    }

    var showsAllFiles: Bool { changes.showsAllFiles }

    func showAllFiles(_ shows: Bool) { changes.showsAllFiles = shows }

    func forgetHeldDiff(for path: String) { changes.forgetHeldDiff(for: path) }

    // MARK: The branch's commits

    var branchCommits: BranchCommitList { history.commits }
    var hasReadBranchCommits: Bool { history.hasRead }
    var historyError: String? { history.problem }
    /// Nothing to add: the rows are the machine's own `git log`, in the tab that has always drawn
    /// them. What a commit still cannot show is its patch, and `scopeNote` says that where it
    /// matters rather than over the whole list.
    var historyNotice: String? { nil }
    func loadMoreCommits() async { await history.loadMore() }

    // MARK: Acting on a file, where the workspace can

    /// Nil: these files are in the cloud. Every capability that would have read it is false, so
    /// nothing offers the action in the first place.
    func absolutePath(for relativePath: String) -> String? { nil }

    func revert(file: ChangedFile) async -> String? {
        WorkspaceCapabilities.Capability.revertChanges.cloudSentence
    }

    func openTerminal(in folder: String) {
        // The workspace's own shell, which is the honest equivalent of a shell in a folder here.
        open(.terminal)
    }

    /// The file, or the branch itself, on GitHub, which is where a Cloud workspace's files really
    /// are. This is what the row offers where a local workspace offers the Finder.
    func gitHubURL(forFile relativePath: String?) -> URL? {
        guard let repository = cloud.item(id)?.project?.repository, !surfaceBranch.isEmpty else { return nil }
        let branch = surfaceBranch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? surfaceBranch
        guard let relativePath, !relativePath.isEmpty else {
            return URL(string: "https://github.com/\(repository)/tree/\(branch)")
        }
        let path = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        return URL(string: "https://github.com/\(repository)/blob/\(branch)/\(path)")
    }

    func openPage(path: String, splittingAxis: SplitAxis?) {
        // A page of a file in the cloud is the preview, which is the browser's business.
        Task { await openPreview() }
    }

    // MARK: What GitHub thinks of it

    /// Nothing yet: runbloom.app is building the pull request state for the list and on demand,
    /// with its merge blockers. Until it lands the header says what it knows, which is nothing,
    /// and `capabilities` keeps the buttons that would act on it greyed with a sentence.
    var pullRequest: PullRequest? { nil }
    var isLoadingPullRequest: Bool { false }
    var pullRequestNotice: PullRequestNotice? {
        get { nil }
        // Nothing here raises one yet, so there is nothing for a dismissal to clear either.
        set { _ = newValue }
    }
    var pullRequestRefreshFailure: GitHubReadFailure? { nil }
    func dismissPullRequestRefreshFailure() {}
    func refreshPullRequest(maxAge: Duration) async {}
    var localWork: LocalWork? { nil }
    var continued: ContinuedBranch? { nil }
    var mergeMethod: GitHub.MergeMethod { MergeMethodChoice.fallback }
    func loadMergeMethod() async {}
    func chooseMergeMethod(_ method: GitHub.MergeMethod) async {}

    /// Composing a turn for the agent is the same act in both kinds of workspace, and the machine
    /// can push and open a pull request itself, so these send the prompt to the chat in front.
    func requestPullRequest(overrides: PromptOverrides) async -> String? {
        await ask("Open a pull request for this branch.")
    }

    func requestPush(overrides: PromptOverrides) async -> String? {
        await ask("Push this branch.")
    }

    func requestMerge(_ pullRequest: PullRequest, method: GitHub.MergeMethod, overrides: PromptOverrides) async -> String? {
        WorkspaceCapabilities.Capability.managePullRequest.cloudSentence
    }

    func requestFixConflicts(_ pullRequest: PullRequest, overrides: PromptOverrides) async -> String? {
        await ask("This branch conflicts with \(surfaceBaseBranch). Fix the merge conflicts.")
    }

    func markReadyForReview(_ pullRequest: PullRequest) async throws {
        throw CloudReviewFailure(message: WorkspaceCapabilities.Capability.managePullRequest.cloudSentence)
    }

    var openInRepoID: RepoID? { nil }

    /// Sends a sentence to the chat in front, which is how every one of these acts on a Cloud
    /// workspace: the machine has the worktree and the git credentials, the Mac has neither.
    private func ask(_ sentence: String) async -> String? {
        guard let chatID = selectedChatID ?? chatIDs.first else {
            return "Open a chat in this Cloud workspace first."
        }
        return await send(sentence, chatID: chatID)
    }

    // MARK: Read marks

    func isViewed(_ file: ChangedFile) -> Bool { changes.isViewed(file) }

    func setViewed(_ isViewed: Bool, file: ChangedFile) async { changes.setViewed(isViewed, file: file) }

    func clearViewedFiles() async { changes.clearViewed() }

    var viewedSummary: String? { changes.viewedSummary }

    // MARK: Every file

    var fileTree: [String: [FileTreeNode]] { changes.fileTree }

    var hasReadFileTree: Bool { changes.hasReadFileTree }

    func refreshFileTree(force: Bool) async { await changes.refreshFileTree(force: force) }

    func contents(of relativePath: String) -> String? { changes.contents(of: relativePath) }
}

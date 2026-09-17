import AppKit
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
extension CloudWorkspaceSession: WorkspaceSurface {
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
            revertChanges: true,
            searchTranscripts: false,
            preview: allows("preview"),
            terminal: allows("terminal"),
            // runbloom.app answers whether this person may merge, as GitHub sees them, so the
            // control is greyed for somebody without push access rather than failing when pressed.
            managePullRequest: github.state?.canMerge == true
        )
    }

    var isRunning: Bool {
        state.chats.values.contains { $0.isRunning }
    }

    // MARK: Its conversations

    /// The machine's chats, in the order it keeps them, as the app's own `Session`. Crew members an
    /// agent started are left out the same way a local workspace leaves them out of its strip:
    /// `topLevelChats` is the machine's own answer to that question.
    var chats: [Session] {
        state.topLevelChats.map(Session.init(cloudChat:))
    }

    /// The workspace snapshot carries every chat, so there is no moment where the list is empty
    /// because nobody has asked: either this workspace has been read or it has not.
    var hasReadChats: Bool { state.workspace != nil }

    var activeChat: Session? {
        guard let id = selectedChatID else { return nil }
        return chats.first { $0.id == id }
    }

    /// Selecting a tab adopts the chat in it, which for a Cloud workspace is the tab strip's own
    /// selection: there is no second place that remembers which conversation is in front.
    var activeChatID: SessionID? {
        get { selectedChatID }
        set {
            guard let newValue else { return }
            select(.chat(newValue))
        }
    }

    // MARK: A conversation in it

    /// The machine's setup, which is what a new Cloud workspace spends its first minutes doing.
    var isRunningSetup: Bool {
        ["pending", "running"].contains(state.setup?.state ?? "")
    }

    /// Kept on the session, so where somebody had got to in a conversation survives switching tab
    /// and switching workspace, exactly as it does for a local one.
    func transcriptMemory(pane: String) -> TranscriptPaneMemory {
        TranscriptPaneMemory(
            pane: pane,
            read: { [weak self] session in self?.panePositions[TranscriptPaneState.Key(pane: pane, session: session)] },
            write: { [weak self] state, session in
                self?.panePositions[TranscriptPaneState.Key(pane: pane, session: session)] = state
            }
        )
    }

    /// No worktree on this Mac, so the composer offers what it offers Ask Bloom.
    var composerWorkspace: WorkspaceModel? { nil }

    /// What runbloom.app would refuse a turn for, said before anything is typed rather than a
    /// minute later with the same sentence and nothing to press.
    func composerNotice(for transcript: TranscriptModel) -> ChatComposerNotice? {
        guard let teamID = cloud.item(id)?.teamID,
              let readiness = CloudPromptReadiness(
                  account: cloud.account, teamID: teamID, agent: transcript.session.agentKind.wireName
              )
        else { return nil }
        return ChatComposerNotice(
            sentence: readiness.sentence,
            actionTitle: readiness.opensRunbloom ? "Open runbloom.app" : nil,
            action: readiness.opensRunbloom ? { [cloud, id] in NSWorkspace.shared.open(cloud.runbloomPage(forWorkspace: id)) } : nil
        )
    }

    /// Nothing hangs over a Cloud conversation: side conversations are a second agent in the same
    /// worktree, and there is no worktree here to hold one.
    func chatLayer(for transcript: TranscriptModel) -> EmptyView { EmptyView() }

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

    /// The same rule a local workspace follows: Checks appears when there is something to report.
    var availableInspectorTabs: [InspectorTab] {
        InspectorTab.available(for: pullRequest)
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
        await changes.revert(file: file)
    }

    func discard(hunk: DiffHunk, of file: ChangedFile) async -> String? {
        await changes.discard(hunk: hunk, of: file)
    }

    /// The file as the machine has it, read once and held, so the expanders between hunks work
    /// the same way they do over a worktree.
    func reviewContents(for file: ChangedFile) async -> String? {
        await changes.text(of: file.path)
    }

    /// No worktree on this Mac to root a language server in, so the diff offers no lookup and
    /// says nothing it cannot do.
    var offersSourceLookup: Bool { false }

    func lookUpInDiff(at offset: Int, view: CodeTextView, lines: [DiffLine?], source: String,
                      path: String, references: Bool, automatic: Bool, newTab: Bool,
                      onOpen: @escaping (CodeLocation, Bool) -> Void) {}

    func openFromDiff(_ location: CodeLocation, newTab: Bool) async {
        openFile(path: location.path, focusing: true)
    }

    /// No source editor to walk, so the buttons that walk it are greyed rather than missing.
    var canStepSourceHistory: (back: Bool, forward: Bool) { (false, false) }
    func stepSourceHistory(_ delta: Int) {}

    /// A line of a file is the review, which is the tab this workspace already has.
    func openSource(at location: CodeLocation) {
        openFile(path: location.path, focusing: true)
    }

    /// No file on this Mac to name, so the key names the workspace and the file. Nothing opens it:
    /// the editor is behind `.editFiles`, which a Cloud workspace does not have.
    func editorKey(for relativePath: String) -> String {
        "cloud:\(id.rawValue)/\(relativePath)"
    }

    func heldDiff(for file: ChangedFile, ignoringWhitespace: Bool) -> DiffPresentation? {
        changes.heldDiff(for: file, ignoringWhitespace: ignoringWhitespace)
    }

    func holdDiff(_ presentation: DiffPresentation, for file: ChangedFile, ignoringWhitespace: Bool) {
        changes.holdDiff(presentation, for: file, ignoringWhitespace: ignoringWhitespace)
    }

    // MARK: Notes on a diff

    /// None, and none can be written: `.reviewComments` is off, so the gutter that starts one is
    /// not drawn. The buffers are the protocol's shape rather than anything in use.
    var reviewComments: [ReviewComment] { [] }
    var reviewDrafts: [String: ReviewDraft] {
        get { changes.reviewDrafts }
        set { changes.reviewDrafts = newValue }
    }
    var reviewEdits: Set<ReviewCommentID> {
        get { changes.reviewEdits }
        set { changes.reviewEdits = newValue }
    }
    var reviewText: ReviewTextHost { changes.reviewText }
    func addReviewComment(filePath: String, selection: ReviewSelection, anchor: ReviewCommentAnchor, body: String) async {}
    func editReviewComment(id: ReviewCommentID, body: String) async {}
    func removeReviewComment(id: ReviewCommentID) async {}

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

    /// What GitHub says about the branch, as runbloom.app last read it: the whole of what the band
    /// draws, checks and merge blockers included. The machine's own `gh` reports a pull request
    /// too, and it is the fallback for the moment before runbloom.app has answered, because it
    /// arrives with the workspace rather than on a request of its own.
    var pullRequest: PullRequest? {
        if let read = github.state { return PullRequest(cloudState: read) }
        return state.workspace?.pullRequest.map { PullRequest(cloudRecord: $0, branch: surfaceBranch) }
    }

    var hasKnownChanges: Bool { !changedFiles.isEmpty }

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
        "Carrying on in a new branch is not built for a Cloud workspace yet. Make another Cloud workspace from the same project."
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
    var pullRequestNotice: PullRequestNotice? {
        get { nil }
        // Nothing here raises one yet, so there is nothing for a dismissal to clear either.
        set { _ = newValue }
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

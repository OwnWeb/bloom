import Foundation
import SwiftUI
import BloomCore

/// `WorkspaceModel` as the shared review views see it.
///
/// Every member but these five already existed with the right name and signature, which is the
/// point: the protocol was written from what the inspector already asks a workspace for, so the
/// local path keeps every line of its behaviour and gains an interface.
extension WorkspaceModel: WorkspaceReviewSurface {
    var surfaceID: WorkspaceSurfaceID { .local(workspace.id) }
    var surfaceName: String { workspace.name }
    var surfaceBranch: String { workspace.branch }
    var surfaceBaseBranch: String { workspace.baseBranch }
    var worktreePath: String? { workspace.path }
    var capabilities: WorkspaceCapabilities { .local }
    var openInRepoID: RepoID? { repo?.id }

    /// The review in the centre column, which is where a local workspace has always opened a file.
    func openFile(path: String, focusing: Bool) {
        FileReview.open(path: path, in: self, focusing: focusing)
    }

    var activeReviewPath: String? { FileReview.activePath(in: self) }

    var showsAllFiles: Bool {
        CenterTabStore.shared.review(for: workspace.id)?.showsAllFiles == true
    }

    func showAllFiles(_ shows: Bool) {
        guard let tab = CenterTabStore.shared.review(for: workspace.id) else { return }
        CenterTabStore.shared.setShowsAllFiles(shows, for: tab)
    }

    func absolutePath(for relativePath: String) -> String? {
        (workspace.path as NSString).appendingPathComponent(relativePath)
    }

    func revert(file: ChangedFile) async -> String? {
        await FileRevert.revert(file: file, in: workspace)
    }

    func discard(hunk: DiffHunk, of file: ChangedFile) async -> String? {
        await FileRevert.discard(hunk: hunk, of: file, in: workspace, scope: diffScope)
    }

    var hasKnownChanges: Bool { !changedFiles.isEmpty || workspace.hasDiff }

    /// Through `gh`, which is what this Mac has. Nil when GitHub refused this token the runs: an
    /// empty list there would say "no checks", which is the one thing that is not known.
    func readChecks() async -> [CheckRun]? {
        await GitHubBridge.checks(for: workspace)
    }

    /// Nil: `gh` is asked when the pane asks, so the answer is as fresh as the question.
    var checksNote: String? { nil }

    var canSendCheckFailure: Bool { activeSession != nil }

    func sendCheckFailure(_ run: CheckRun) async -> String? {
        await checkFailures.send(run, in: self)
    }

    var gitHubReadiness: GitHubAvailability.State { GitHubAvailability.shared.state }

    /// Nothing in the way: a worktree on this Mac is what Continue cuts the new branch in.
    var continueBlocker: String? { nil }

    func continueAfterMerge(_ pullRequest: PullRequest) async -> AppModel.ContinuationOutcome {
        await app.continueAfterMerge(workspace, pullRequest: pullRequest)
    }

    func requestArchive(presenting: @escaping (ArchiveRequest) -> Void) async {
        await app.archive(workspace, presentConfirmation: presenting)
    }

    func confirmArchive(_ request: ArchiveRequest, presenting: @escaping (ArchiveRequest) -> Void) async {
        await app.confirmArchive(request, presentConfirmation: presenting)
    }

    func reviewContents(for file: ChangedFile) async -> String? {
        await Self.reviewContents(worktree: workspace.path, file: file, scope: diffScope)
    }

    var offersSourceLookup: Bool { true }

    func lookUpInDiff(at offset: Int, view: CodeTextView, lines: [DiffLine?], source: String,
                      path: String, references: Bool, automatic: Bool, newTab: Bool,
                      onOpen: @escaping (CodeLocation, Bool) -> Void) {
        SourceActions.lookupInDiff(at: offset, view: view, lines: lines, source: source, path: path,
                                   model: self, references: references, automatic: automatic,
                                   newTab: newTab, onOpen: onOpen)
    }

    func openFromDiff(_ location: CodeLocation, newTab: Bool) async {
        await FileReview.openFromDiff(location, in: self, newTab: newTab)
    }

    var canStepSourceHistory: (back: Bool, forward: Bool) {
        let history = SourceNavigation.shared.histories[workspace.id]
        return (history?.canGoBack == true, history?.canGoForward == true)
    }

    func stepSourceHistory(_ delta: Int) {
        SourceNavigation.shared.move(delta, in: self)
    }

    func openSource(at location: CodeLocation) {
        FileReview.open(location: location, in: self)
    }

    /// The file itself, which is what the editor opens and what the find bar files its state under.
    func editorKey(for relativePath: String) -> String {
        (workspace.path as NSString).appendingPathComponent(relativePath)
    }

    func openTerminal(in folder: String) {
        FolderTerminalTab.open(folder: folder, in: self)
    }

    /// Nil: the file is on this Mac, and the menu offers the Finder and an editor instead.
    func gitHubURL(forFile relativePath: String?) -> URL? { nil }

    func openPage(path: String, splittingAxis: SplitAxis?) {
        if let axis = splittingAxis {
            BrowserTab.splitFile(path, in: self, axis: axis)
        } else {
            BrowserTab.openFile(path, in: self)
        }
    }
}

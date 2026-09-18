import AppKit
import BloomClient
import Foundation
import SwiftUI
import BloomCore
import BloomProtocol

/// What the machine's agent changed, as the inspector and the review panes ask for it: the
/// changed files, their patches, the branch's commits, the whole file list and the read marks.
/// The reads themselves are `CloudChanges` and `CloudHistory`, which hold the caches.
extension CloudWorkspaceSession {
    // MARK: What changed

    var diffScope: BloomCore.DiffScope { changes.localScope }

    func setDiffScope(_ scope: BloomCore.DiffScope) {
        changes.setScope(scope)
    }

    var scopeNote: String? { changes.scopeNote }

    var changedFiles: [ChangedFile] { changes.files.map(ChangedFile.init(cloudRecord:)) }

    /// The same order the local review reads in, from the same rule: the tree's order where every
    /// row is a whole file, and the list's own where a file can appear twice under two layers.
    var reviewFiles: [ChangedFile] {
        let files = changedFiles
        return files.contains { $0.layer != nil } ? files : ChangedFileTree.orderedFiles(from: files)
    }

    func selectedChangedFile(path: String) -> ChangedFile? {
        changedFiles.first { $0.path == path && $0.layer == changes.selectedLayer }
            ?? changedFiles.first { $0.path == path }
    }

    /// Read out of this Mac's defaults when the workspace was opened, so there is no moment where
    /// the marks are unknown.
    var hasReadViewedFiles: Bool { true }

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
        open(.review)
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
        changes.selectedPath.flatMap { selectedChangedFile(path: $0) }?.id
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

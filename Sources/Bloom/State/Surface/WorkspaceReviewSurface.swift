import Foundation
import SwiftUI
import BloomCore
import Observation

/// Why the changed files are being read, which decides how loudly it happens.
///
/// Top level rather than nested in `WorkspaceModel`, because both kinds of workspace take it
/// now and a nested type would have made the protocol name one of the two implementations.
enum ChangesRefresh {
    /// The reader did something that changed the worktree, or the pane has just opened.
    /// Reports progress, and opens the first file when nothing is open.
    case requested
    /// The poll that keeps the list honest while an agent writes. It has to be invisible: a
    /// spinner every six seconds says less than a list one tick out of date, and moving the
    /// selection would reopen a diff the reader had just closed.
    case quiet
}

/// What the inspector and the review panes need of a workspace, whichever kind it is.
///
/// **One set of views, two implementations.** `WorkspaceModel` answers this out of the worktree on
/// this Mac and the database beside it; `CloudWorkspaceSession` answers it over the workspace
/// protocol from the machine. The views are generic over this, so a reader cannot tell which they
/// are looking at, and neither can the code they are drawn by.
///
/// **Generic rather than `any WorkspaceReviewSurface`, and that is not a preference.** SwiftUI's
/// `@Bindable` refuses an existential ("the wrapped value must be an object that conforms to
/// Observable"), and the inspector binds a selection and a scope. Generic views keep the binding
/// and keep every type static, so the redraw behaviour the centre and right columns were tuned for
/// is exactly what it was.
///
/// What is deliberately not here: anything that needs a path on this Mac. A reveal, an editor, a
/// revert and a local shell are `WorkspaceCapabilities`, asked before they are offered.
@MainActor
protocol WorkspaceReviewSurface: AnyObject, Observable {
    /// What Edit mode in a diff shows. See `WorkspaceModel.editorPane(path:session:)` for why
    /// the workspace builds this view and the diff does not.
    associatedtype EditorPane: View
    func editorPane(path: String, session: FileEditSession) -> EditorPane

    /// What this workspace is, for the caches that are keyed per workspace and for a view that has
    /// to tell two of them apart. See `WorkspaceSurfaceID`.
    var surfaceID: WorkspaceSurfaceID { get }
    var surfaceName: String { get }
    var surfaceBranch: String { get }
    var surfaceBaseBranch: String { get }
    /// The worktree on this Mac, or nil for a workspace whose files are in the cloud. Only a
    /// capability that is already false for a Cloud workspace reads it.
    var worktreePath: String? { get }
    var capabilities: WorkspaceCapabilities { get }

    /// Whether an agent is working in it, which the list uses to decide how hard to poll.
    var isRunning: Bool { get }

    // MARK: What changed

    var diffScope: DiffScope { get }
    func setDiffScope(_ scope: DiffScope)
    var scopeNote: String? { get }
    var changedFiles: [ChangedFile] { get }
    var changesError: String? { get }
    var hasReadChanges: Bool { get }
    var isLoadingChanges: Bool { get }
    /// Bumped whenever the files could have moved, so a pane holding a diff knows to read again.
    var changesGeneration: Int { get }
    func refreshChanges(_ reason: ChangesRefresh) async
    func readPatch(for file: ChangedFile) async throws -> String
    /// What the review pane last drew for this file, so a diff the app already has goes on screen
    /// on the frame the tab is picked rather than after a read.
    func heldDiff(for file: ChangedFile, ignoringWhitespace: Bool) -> DiffPresentation?
    func holdDiff(_ presentation: DiffPresentation, for file: ChangedFile, ignoringWhitespace: Bool)

    /// Opens one of this workspace's files where its reader expects it: the review in the centre
    /// column for a worktree on this Mac, the same review for a workspace on a machine.
    func openFile(path: String, focusing: Bool)

    /// The file the review is pointed at, which the list and the panes share.
    var selectedFilePath: String? { get set }
    var selectedChangeLayer: ChangeLayer? { get set }
    var selectedChangeID: String? { get }
    /// The file the review pane in front is actually showing, which is not always the selection:
    /// a pinned tab holds its own file. The tree reads it to open its way down to that file when
    /// a workspace comes on screen.
    var activeReviewPath: String? { get }

    // MARK: Read marks

    func isViewed(_ file: ChangedFile) -> Bool
    func setViewed(_ isViewed: Bool, file: ChangedFile) async
    func clearViewedFiles() async
    var viewedSummary: String? { get }

    // MARK: The inspector's own state

    var inspectorTab: InspectorTab { get set }
    var availableInspectorTabs: [InspectorTab] { get }
    /// Whether the review pane is showing every file rather than one, which the list follows.
    var showsAllFiles: Bool { get }
    func showAllFiles(_ shows: Bool)
    /// Drops what a pane is holding for a file whose contents have just been rewritten under it.
    func forgetHeldDiff(for path: String)

    // MARK: The branch's commits

    var branchCommits: BranchCommitList { get }
    var hasReadBranchCommits: Bool { get }
    var historyError: String? { get }
    var historyNotice: String? { get }
    func loadMoreCommits() async

    // MARK: Acting on a file, where the workspace can

    /// The file on this Mac, for the things only a local worktree has: a reveal, an editor, a drag.
    /// Nil in the cloud, and every capability that reads it is false there.
    func absolutePath(for relativePath: String) -> String?
    /// Takes a file back to what it was. Answers what went wrong, or nil. Behind `.revertChanges`.
    func revert(file: ChangedFile) async -> String?
    /// The same for one hunk of it, named by the hunk the reader is looking at rather than by an
    /// index, so a file that moved under the diff is refused rather than guessed at.
    func discard(hunk: DiffHunk, of file: ChangedFile) async -> String?
    /// Where the source editor's back and forward buttons can go, and stepping them. A workspace
    /// whose files are not on this Mac has no source editor to walk, so it answers false and the
    /// buttons are greyed rather than absent.
    var canStepSourceHistory: (back: Bool, forward: Bool) { get }
    func stepSourceHistory(_ delta: Int)
    /// Opens a file at a line, which is what a link in a diff or a preview means. Behind
    /// `.editFiles` where there is no source editor to open.
    func openSource(at location: CodeLocation)
    /// The file as the review's baseline has it, which is what the between-hunks expanders
    /// reveal. Nil where it cannot be read, and then the diff simply has no expanders.
    func reviewContents(for file: ChangedFile) async -> String?
    /// Go to definition and find usages from a diff line. Both need a language server rooted in a
    /// worktree on this Mac, so a workspace without one offers neither and the diff is read-only
    /// in that one respect rather than pretending.
    var offersSourceLookup: Bool { get }
    func lookUpInDiff(at offset: Int, view: CodeTextView, lines: [DiffLine?], source: String,
                      path: String, references: Bool, automatic: Bool, newTab: Bool,
                      onOpen: @escaping (CodeLocation, Bool) -> Void)
    /// Opens what a lookup found, in this pane or a new tab.
    func openFromDiff(_ location: CodeLocation, newTab: Bool) async
    /// What the editor, the find bar and the source state file this file under.
    ///
    /// The path on this Mac for a worktree, and a key naming the Cloud workspace and the file for
    /// one in the cloud. It is a key and not a path: nothing opens it, and everything that reads
    /// or writes the file itself is behind `.editFiles` or `.revealFiles`.
    func editorKey(for relativePath: String) -> String
    /// A shell opened in one of the workspace's folders. Behind `.terminal`.
    func openTerminal(in folder: String)
    /// The file shown as a page, which is how a local workspace previews an image or a PDF.
    func openPage(path: String, splittingAxis: SplitAxis?)
    /// The same file, or the branch itself, on GitHub. The honest equivalent of a reveal for a
    /// workspace whose files are not on this Mac; nil where the files are here.
    func gitHubURL(forFile relativePath: String?) -> URL?

    // MARK: Notes on a diff

    /// The pending review: what has been written on this workspace's diffs and not yet sent.
    /// Empty where `.reviewComments` is missing, and the gutter that would add one is not drawn.
    var reviewComments: [ReviewComment] { get }
    /// Where a note is being written on each file, and which finished notes are open for editing.
    /// On the workspace rather than in the view, because the view is destroyed by scrolling.
    var reviewDrafts: [String: ReviewDraft] { get set }
    var reviewEdits: Set<ReviewCommentID> { get set }
    /// What is being typed into those. A `let` on both implementations, so a keystroke invalidates
    /// the one editor row reading its key rather than the diff.
    var reviewText: ReviewTextHost { get }
    func addReviewComment(filePath: String, selection: ReviewSelection, anchor: ReviewCommentAnchor, body: String) async
    func editReviewComment(id: ReviewCommentID, body: String) async
    func removeReviewComment(id: ReviewCommentID) async

    // MARK: What GitHub thinks of it

    var pullRequest: PullRequest? { get }
    var isLoadingPullRequest: Bool { get }
    var pullRequestNotice: PullRequestNotice? { get set }
    var pullRequestRefreshFailure: GitHubReadFailure? { get }
    func dismissPullRequestRefreshFailure()
    func refreshPullRequest(maxAge: Duration) async
    /// What this branch is holding that GitHub has not been told about.
    var localWork: LocalWork? { get }
    var continued: ContinuedBranch? { get }
    var mergeMethod: GitHub.MergeMethod { get }
    func loadMergeMethod() async
    func chooseMergeMethod(_ method: GitHub.MergeMethod) async
    /// Each of these composes a turn for the agent rather than doing the git itself, which is why
    /// they are the same on both kinds of workspace. They answer what went wrong, or nil.
    func requestPullRequest(overrides: PromptOverrides) async -> String?
    func requestPush(overrides: PromptOverrides) async -> String?
    func requestMerge(_ pullRequest: PullRequest, method: GitHub.MergeMethod, overrides: PromptOverrides) async -> String?
    func requestFixConflicts(_ pullRequest: PullRequest, overrides: PromptOverrides) async -> String?
    func markReadyForReview(_ pullRequest: PullRequest) async throws
    /// The project a row's Open in menu belongs to, for the applications this Mac has.
    var openInRepoID: RepoID? { get }

    // MARK: Every file

    var fileTree: [String: [FileTreeNode]] { get }
    var hasReadFileTree: Bool { get }
    func refreshFileTree(force: Bool) async
    func contents(of relativePath: String) -> String?
}

extension WorkspaceReviewSurface {
    func refreshPullRequest() async { await refreshPullRequest(maxAge: .zero) }
    func requestPullRequest() async -> String? { await requestPullRequest(overrides: PromptOverrides()) }
    func requestPush() async -> String? { await requestPush(overrides: PromptOverrides()) }

    /// The reader asked, which is what nearly every call site means.
    func refreshChanges() async { await refreshChanges(.requested) }

    func openFile(path: String) { openFile(path: path, focusing: false) }

    /// Read it if it has not been read, which is what opening the tab means.
    func refreshFileTree() async { await refreshFileTree(force: false) }
}

/// Which workspace a surface is, for the stores that are keyed by one.
///
/// Two cases rather than one string, for `SidebarSelection`'s reason: a Cloud id and a local id are
/// drawn from different places and a lookup that took either would find nothing and say nothing.
enum WorkspaceSurfaceID: Hashable, Sendable {
    case local(WorkspaceID)
    case cloud(CloudWorkspaceID)

    /// The key a per-workspace store files this under. Namespaced, so a Cloud workspace whose id
    /// happened to match a local one cannot read its tabs, its viewed marks or its drafts.
    var storageKey: String {
        switch self {
        case .local(let id): id.rawValue
        case .cloud(let id): "cloud:" + id.rawValue
        }
    }

    var local: WorkspaceID? {
        if case .local(let id) = self { return id }
        return nil
    }
}

import AppKit
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
/// **Generic rather than `any WorkspaceSurface`, and that is not a preference.** SwiftUI's
/// `@Bindable` refuses an existential ("the wrapped value must be an object that conforms to
/// Observable"), and the inspector binds a selection and a scope. Generic views keep the binding
/// and keep every type static, so the redraw behaviour the centre and right columns were tuned for
/// is exactly what it was.
///
/// What is deliberately not here: anything that needs a path on this Mac. A reveal, an editor, a
/// revert and a local shell are `WorkspaceCapabilities`, asked before they are offered.
@MainActor
protocol WorkspaceSurface: AnyObject, Observable {
    /// What one of this workspace's tool tabs fills a pane with: a terminal, a page, the review or
    /// the notes over a worktree on this Mac; the machine's own terminal, review and setup log for
    /// a Cloud workspace. Everything around it, the strip, the panes, the splits, the menus, is one
    /// view over both.
    associatedtype ToolPane: View
    @MainActor func toolPane(
        for tab: CenterTab,
        siblings: [PaneContent],
        splitColumn: @escaping @MainActor (SplitAxis, PaneKind) -> Void,
        paneMenu: (@MainActor () -> NSMenu)?
    ) -> ToolPane

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

    // MARK: Its conversations

    /// The chats the strip may draw a tab for, in the order the workspace keeps them. A local
    /// workspace's are rows in this Mac's database; a Cloud workspace's are its machine's.
    var chats: [Session] { get }
    /// Whether that list is an answer rather than a list nobody has read yet. An empty list is
    /// also what a workspace with no chats looks like, and the reconciliation that deletes panes
    /// nothing answers for has to tell the two apart.
    var hasReadChats: Bool { get }
    /// Which chat the rest of the window is talking about, which selecting a tab adopts.
    var activeChat: Session? { get }
    var activeChatID: SessionID? { get set }

    /// What the centre column does when it arrives on this workspace: a local one reads its
    /// sessions and its settings, a Cloud one opens its connection and marks it read.
    func onColumnAppear() async
    /// The project's run scripts, which the `+` menu offers and whose autostart the column
    /// settles. Empty where the workspace has no settings file on this Mac.
    var runScripts: [RunScript] { get }
    func considerRunScriptAutostart()
    /// Runs one, or shows the tab it is already running in. See `RunScriptLauncher`.
    func pickRunScript(_ script: RunScript)
    /// The file a run script names and cannot find, for the menu row that says so. Nil when it is
    /// there, and for a workspace whose scripts are not on this Mac to look for.
    func missingRunScriptFile(_ script: RunScript) -> String?
    /// Opening the three tabs the `+` offers besides a chat and a terminal. Each kind a workspace
    /// does not have is absent from the menu rather than greyed: see `NewTabMenu`.
    func openReview()
    var supportsNotes: Bool { get }
    func openNotes()
    var supportsSetupTab: Bool { get }
    func openSetupLog()
    /// Re-reads the project's settings, for the moment somebody comes back to the window having
    /// edited them elsewhere.
    func refreshSettings()
    /// What the column says above the panes about this workspace's settings: a run script asking
    /// to start, a settings file that will not parse. A Cloud workspace has neither on this Mac.
    associatedtype SettingsNotices: View
    @MainActor func settingsNotices() -> SettingsNotices

    /// Whether an agent is mid turn in this one chat, which is what lights its tab.
    func isRunningChat(_ id: SessionID) -> Bool

    /// The transcript of one chat, when this launch has built it. A lookup, never a build: a body
    /// may not write observed state, which is what `prepareTranscript` is for.
    func existingTranscript(for id: SessionID) -> TranscriptModel?
    /// Builds it if it has not been built, from a task rather than from a body.
    func prepareTranscript(for id: SessionID)

    /// Makes a chat and answers what to put in front of the reader, or nil when it could not be
    /// made. A local workspace writes a row and may start a CLI; a Cloud workspace asks its
    /// machine. Nothing is placed before the thing exists: see `NewPane`.
    func createChat(title: String?) async -> PaneContent?
    /// Closing one, which asks what closing costs where there is anything to lose.
    func closeChat(_ session: Session)
    func renameChat(_ session: Session, to title: String)
    /// The order the chats are in among themselves, after a drag in the strip. The interleaving of
    /// chats and tools is the strip's own and is written by `WorkspaceTabsStore`.
    func reorderChats(to order: [SessionID])
    /// The project's run script of this id, for the tab a run script opened. Nil where the
    /// workspace has no settings file on this Mac to read.
    func runScript(id: String) -> RunScript?
    /// Where a new browser tab opens, which is the workspace's own dev server when it has one.
    func browserAddress() async -> String
    /// Whether a browser tab is one of the kinds this workspace can open at all.
    var supportsBrowserTabs: Bool { get }

    // MARK: A conversation in it

    /// Whether the workspace's own setup is running, which the transcript draws a row for.
    var isRunningSetup: Bool { get }
    /// Where the reader had got to in each conversation, per pane. Kept by the workspace, because
    /// the pane and the list that draw it are both destroyed by switching tab.
    func transcriptMemory(pane: String) -> TranscriptPaneMemory
    /// The worktree behind the composer, for the parts of it that are about files on this Mac:
    /// attaching one, the project's quick prompts, its run scripts. Nil where there is no worktree,
    /// and the composer offers those the way it does for Ask Bloom, which has none either.
    var composerWorkspace: WorkspaceModel? { get }
    /// What is missing before a turn in this chat could start, said before anything is typed
    /// rather than as a refusal a minute later. Nil when nothing is.
    func composerNotice(for transcript: TranscriptModel) -> ChatComposerNotice?
    /// What this workspace hangs over a conversation of its own accord: a local one its side
    /// conversations and the pill back to the chat a side conversation was opened from, a Cloud
    /// one nothing at all. A view rather than a flag, because what is drawn is a whole layer with
    /// its own placement, and a capability cannot carry that.
    associatedtype ChatLayer: View
    @MainActor func chatLayer(for transcript: TranscriptModel) -> ChatLayer

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
    /// The checks on the branch's head commit, or nil when they could not be read at all, which
    /// is a different thing from a branch with no checks on it and is drawn differently.
    func readChecks() async -> [CheckRun]?
    /// How old the checks are, for a workspace whose answer is cached rather than asked for on the
    /// spot. Nil where the answer is as fresh as the question.
    var checksNote: String? { get }
    /// Whether a failed check can be handed to an agent from here, and doing it. Answers what went
    /// wrong, or nil.
    var canSendCheckFailure: Bool { get }
    func sendCheckFailure(_ run: CheckRun) async -> String?
    /// Whether the branch has anything on it at all, for the strip that offers to open a pull
    /// request: the changed files first, and whatever the workspace already knew behind them.
    var hasKnownChanges: Bool { get }
    /// What this Mac knows about GitHub, which is what decides whether the strip may say there is
    /// no pull request. A workspace whose machine asks GitHub itself is never in the dark.
    var gitHubReadiness: GitHubAvailability.State { get }
    /// Whether this workspace can be carried on to a fresh branch where it stands. Nil when it
    /// can; the sentence when it cannot, for the control that stays and says so.
    var continueBlocker: String? { get }
    func continueAfterMerge(_ pullRequest: PullRequest) async -> AppModel.ContinuationOutcome
    /// Archiving from the strip. Each kind raises its own confirmation, because what is lost and
    /// how it is checked are different questions; a local one comes back through `presenting`.
    func requestArchive(presenting: @escaping (ArchiveRequest) -> Void) async
    func confirmArchive(_ request: ArchiveRequest, presenting: @escaping (ArchiveRequest) -> Void) async
    /// The project a row's Open in menu belongs to, for the applications this Mac has.
    var openInRepoID: RepoID? { get }

    // MARK: Every file

    var fileTree: [String: [FileTreeNode]] { get }
    var hasReadFileTree: Bool { get }
    func refreshFileTree(force: Bool) async
    func contents(of relativePath: String) -> String?
}

extension WorkspaceSurface {
    func refreshPullRequest() async { await refreshPullRequest(maxAge: .zero) }
    func requestPullRequest() async -> String? { await requestPullRequest(overrides: PromptOverrides()) }
    func requestPush() async -> String? { await requestPush(overrides: PromptOverrides()) }
    func requestMerge(_ pullRequest: PullRequest, method: GitHub.MergeMethod) async -> String? {
        await requestMerge(pullRequest, method: method, overrides: PromptOverrides())
    }
    func requestFixConflicts(_ pullRequest: PullRequest) async -> String? {
        await requestFixConflicts(pullRequest, overrides: PromptOverrides())
    }

    /// The reader asked, which is what nearly every call site means.
    func refreshChanges() async { await refreshChanges(.requested) }

    func openFile(path: String) { openFile(path: path, focusing: false) }

    /// Read it if it has not been read, which is what opening the tab means.
    func refreshFileTree() async { await refreshFileTree(force: false) }
}

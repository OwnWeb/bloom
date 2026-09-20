import BloomClient
import BloomCore
import BloomProtocol
import Foundation
import Observation

/// What a Cloud workspace's review reads from its machine: the changed files, the patches, the
/// whole file list and the contents of a file, plus the read marks, which are this reader's own.
///
/// It is the Cloud half of `WorkspaceSurface`, kept apart from the session for the reason
/// `WorkspaceModel` keeps its own review together: this is the only part of a workspace that is
/// read again and again while somebody scrolls, and it has caches (`CloudReviewCache`) that nothing
/// else should be able to reach into.
///
/// **Read when looked at, when a turn ends, and while somebody is looking, never on a timer.**
///
/// The long poll was refused once, on the belief that a held `review_snapshot(wait: true)` would
/// keep a machine from sleeping and cost real money, and the `review` event was to be the hint
/// instead. Both halves of that were wrong. Nothing emits the event: it is a case in the protocol
/// and a line in a decoder, and no machine has ever sent one. And `RemoteAwakePolicy` does not
/// count a held read as a reason to stay awake, nor as the human input that renews the presence
/// lease, so the poll costs nothing but a request.
///
/// What it does cost is a WAKE. A request to a paused machine is answered, and answering is
/// waking, so the poll stops the moment the connection is not live and is not started again by
/// itself: somebody doing something is what starts it. That is the one discipline this has to
/// hold, and it is why `watch` asks the phase every time round rather than trusting the loop.
@MainActor
@Observable
final class CloudChanges {
    /// The scope as the app spells it, so the same menu and the same picker drive both kinds of
    /// workspace, including a commit picked in History.
    private(set) var localScope: BloomCore.DiffScope = .all
    private(set) var files: [ChangedFileRecord] = []
    private(set) var hasRead = false
    private(set) var isLoading = false
    private(set) var problem: String?
    /// Bumped whenever the files or a patch could have moved, which is what a pane holding a diff
    /// watches. The local model has the same counter for the same reason.
    private(set) var generation = 0
    var selectedPath: String? {
        didSet { if selectedPath != oldValue { Task { await loadPatchForSelection() } } }
    }
    /// Which staging layer of that file is open, for a scope that separates them. Nil is the whole
    /// file, which is every row of the branch comparison.
    var selectedLayer: ChangeLayer?
    /// Which of the inspector's tabs this workspace is on, and whether its review is showing every
    /// file. The local model keeps the same two facts; they are per workspace and not per window.
    ///
    /// Coming back to Changes asks again, which is the "read when looked at" half of the policy at
    /// the head of this file. A local workspace has a poll behind its list and this has events, and
    /// an event that arrived while the reader was on Checks changed a list nobody was drawing.
    var inspectorTab: InspectorTab = .changes {
        didSet {
            guard inspectorTab != oldValue else { return }
            reconsiderWatching()
            guard inspectorTab == .changes else { return }
            Task { await refresh(quietly: hasRead) }
        }
    }
    var showsAllFiles = false
    /// What the review pane last drew per file, so walking back to a file it has already read
    /// costs no request. The local model holds the same cache for the same reason.
    @ObservationIgnored private var presentations = DiffPresentationCache()
    /// The notes written on this workspace's diffs and not yet sent.
    ///
    /// **Kept on this Mac, not on the machine, and that is the same choice a local workspace
    /// makes.** A note is one person's own reminder of what to ask for next, in a state where they
    /// have not asked for anything yet: locally it is a row in this Mac's database, and putting a
    /// Cloud workspace's in its machine would publish half-written thoughts to everybody else in
    /// the workspace and lose them when it is archived. They go where the read marks go, under the
    /// workspace's own key, for the same reason.
    private(set) var reviewComments: [ReviewComment] = []
    /// Where a note is being written and which are open for editing.
    var reviewDrafts: [String: ReviewDraft] = [:]
    var reviewEdits: Set<ReviewCommentID> = []
    let reviewText = ReviewTextHost()
    private(set) var fileTree: [String: [FileTreeNode]] = [:]
    private(set) var hasReadFileTree = false

    @ObservationIgnored private weak var session: CloudWorkspaceSession?
    @ObservationIgnored private var caches: [BloomProtocol.DiffScope: CloudReviewCache] = [:]
    /// The contents of files somebody has opened in All files, which the protocol reads one at a
    /// time. Held because `contents(of:)` is what the local model answers from disk without an
    /// await, and a pane asking for a file it already has must not blink.
    @ObservationIgnored private var contentsByPath: [String: String] = [:]
    /// One commit's file, and the patch it was read as. A commit is immutable, so this never
    /// goes stale; it is thrown away with the workspace.
    @ObservationIgnored private var commitPatches: [CommitFile: String] = [:]
    @ObservationIgnored private var contentsBeingRead: Set<String> = []
    /// Owns the state written by an explicit refresh across its suspension. A newer refresh makes
    /// every result, failure and loading cleanup from the older one stale.
    @ObservationIgnored private var refreshGeneration = 0
    /// Which files this reader has ticked, and what the file's diff looked like when they did.
    /// Kept on this Mac under the workspace's own key, because a read mark is one person's note to
    /// themselves; the local ones live in this Mac's database for the same reason.
    private var viewed: [String: String] = [:]

    init(session: CloudWorkspaceSession) {
        self.session = session
        viewed = (UserDefaults.standard.dictionary(forKey: Self.viewedKey(session.id)) as? [String: String]) ?? [:]
        reviewComments = Self.storedComments(session.id)
    }

    private static func viewedKey(_ id: CloudWorkspaceID) -> String { "cloud.viewedFiles.\(id.rawValue)" }
    private static func commentsKey(_ id: CloudWorkspaceID) -> String { "cloud.reviewComments.\(id.rawValue)" }

    private static func storedComments(_ id: CloudWorkspaceID) -> [ReviewComment] {
        guard let data = UserDefaults.standard.data(forKey: commentsKey(id)),
              let stored = try? JSONDecoder().decode([ReviewComment].self, from: data) else { return [] }
        return stored.sortedForReview()
    }

    // MARK: Notes on a diff

    /// A note on a line, which rides with whatever this workspace sends next.
    ///
    /// The workspace id on the note is this Cloud workspace's, spelled as a `WorkspaceID` because
    /// that is the field's type and the note is never handed to anything that would look a row up
    /// by it: these live here rather than in this Mac's database. It is kept rather than left
    /// blank so that a note always says which workspace it belongs to, whichever kind it is.
    func addComment(filePath: String, side: ReviewCommentSide, anchor: ReviewCommentAnchor, body: String) {
        guard let session else { return }
        let comment = ReviewComment(
            workspaceID: WorkspaceID(session.id.rawValue),
            filePath: filePath, side: side, anchor: anchor, body: body
        )
        reviewComments = (reviewComments + [comment]).sortedForReview()
        saveComments()
    }

    func editComment(id: ReviewCommentID, body: String) {
        guard let index = reviewComments.firstIndex(where: { $0.id == id }) else { return }
        reviewComments[index].body = body
        saveComments()
    }

    func removeComments(ids: Set<ReviewCommentID>) {
        guard reviewComments.contains(where: { ids.contains($0.id) }) else { return }
        reviewComments.removeAll { ids.contains($0.id) }
        saveComments()
    }

    private func saveComments() {
        guard let session else { return }
        guard let data = try? JSONEncoder().encode(reviewComments) else { return }
        UserDefaults.standard.set(data, forKey: Self.commentsKey(session.id))
    }

    /// The scope the machine understands for the two comparisons it measures continuously. A
    /// commit is not one of them: its files are `commit_files`, read for the one commit somebody
    /// opened, so `wireScope` is only asked for when the review is not historical.
    private var wireScope: BloomProtocol.DiffScope {
        localScope == .uncommitted ? .uncommitted : .branch
    }

    /// The commit the review is pointed at, or nil for the two continuous comparisons.
    private var commit: BranchCommit? {
        if case .commit(let commit) = localScope { return commit }
        return nil
    }

    /// What a machine that is too old to answer `commit_patch` gets said about it. Guarded on
    /// what the machine answers rather than on a version: an older one refuses the operation as
    /// an invalid request, and the day it is updated this sentence stops appearing by itself.
    static let noCommitPatch = "This Bloom Cloud workspace is running a version that cannot read the"
        + " diff of one commit. It can once the workspace has been updated."

    /// Nothing here throws away a commit, on either kind of workspace. The review's own controls
    /// are already hidden in a historical scope; this is what a caller that got past them is told.
    static let commitIsMade = "This change is already committed. Discarding is for the work in"
        + " front of the last commit."

    /// Set the first time a machine refuses `commit_patch` as an operation it does not know, which
    /// is what one running a version from before it existed answers. Nothing else sets it, so the
    /// sentence stops appearing the moment the workspace is updated.
    private(set) var cannotReadCommitPatches = false

    var scopeNote: String? {
        commit != nil && cannotReadCommitPatches ? Self.noCommitPatch : nil
    }

    func setScope(_ scope: BloomCore.DiffScope) {
        guard scope != localScope else { return }
        localScope = scope
        Task { await refresh() }
    }

    // MARK: Reading

    func refresh(quietly: Bool = false) async {
        guard let session else { return }
        // **Nothing to read while the machine is still making the worktree, so nothing is asked.**
        //
        // The owner's new workspace put "`git` exited 128: '.invalid' is not a valid branch name"
        // in the inspector, in place of the calm and true "Nothing has changed on this branch yet".
        // The client cannot produce that string and neither can the runner's own sources: it is
        // git's, raised on the machine while it resolves a repository that is being cloned as the
        // question arrives. A question asked before there is anything to answer it with gets an
        // answer about the asking, and an error in front of a person is worse than a wait.
        //
        // So the state of setup is the gate. `hasRead` deliberately stays false, which is what the
        // inspector draws its own sentence from: see `isSettingUp`.
        guard !session.isRunningSetup else { return }
        refreshGeneration += 1
        let requestGeneration = refreshGeneration
        if let commit {
            await refreshCommit(commit, quietly: quietly, requestGeneration: requestGeneration)
            return
        }
        let scope = wireScope
        var cache = caches[scope] ?? CloudReviewCache()
        isLoading = !quietly
        defer {
            if requestGeneration == refreshGeneration { isLoading = false }
        }
        do {
            let result = try await session.perform(.reviewSnapshot(scope: scope, knownRevision: cache.revision, wait: false))
            guard case .reviewSnapshot(let snapshot) = result else { return }
            guard requestGeneration == refreshGeneration, scope == wireScope else { return }
            cache.absorb(snapshot)
            caches[scope] = cache
            if files != cache.files {
                files = cache.files
                generation += 1
            }
            hasRead = true
            problem = nil
            if selectedPath == nil || cache.file(selectedPath ?? "") == nil {
                selectedPath = files.first?.path
            }
        } catch {
            guard requestGeneration == refreshGeneration, scope == wireScope else { return }
            problem = error.message
            hasRead = true
        }
    }

    // MARK: Watching

    /// The held read, or nil while nobody is looking or the machine is not live.
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// Whether anything is drawing this list: the inspector's Changes tab, or a review tab.
    private var isBeingRead: Bool {
        inspectorTab == .changes || session?.hasReviewTab == true
    }

    /// Starts or stops the held read to match who is looking and whether the machine is live.
    ///
    /// Called from every place that changes either answer, and safe to call when nothing has
    /// changed: an already running watcher is left alone rather than restarted, because restarting
    /// it would drop a wait that is part way through its fifteen seconds and ask the machine again
    /// for an answer it is already holding.
    func reconsiderWatching() {
        guard isBeingRead, session?.phase == .live, session?.isRunningSetup == false else {
            watcher?.cancel()
            watcher = nil
            return
        }
        guard watcher == nil else { return }
        watcher = Task { [weak self] in await self?.watch() }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    /// One held read after another, for as long as somebody is looking at a live machine.
    ///
    /// The machine holds the request until its revision moves or its own budget runs out, which is
    /// fifteen seconds, and answers with the files either way. So a file written by a person in the
    /// workspace's terminal, or by a script the setup started, reaches the list without anybody
    /// having ended a turn. That was the one case the other two paths cannot serve.
    ///
    /// **A read that fails is not drawn as a failure.** A poll in flight when the machine pauses
    /// dies exactly as a dropped connection does, which is the ordinary end of this loop rather
    /// than something to put in front of a reader. `problem` is left alone and the loop stops.
    private func watch() async {
        while !Task.isCancelled {
            guard let session, session.phase == .live, !session.isRunningSetup, isBeingRead else { return }
            if commit != nil { return }
            let scope = wireScope
            var cache = caches[scope] ?? CloudReviewCache()
            do {
                let result = try await session.perform(
                    .reviewSnapshot(scope: scope, knownRevision: cache.revision, wait: true)
                )
                guard case .reviewSnapshot(let snapshot) = result else { return }
                cache.absorb(snapshot)
                caches[scope] = cache
                guard scope == wireScope else { return }
                if files != cache.files {
                    files = cache.files
                    generation += 1
                    if selectedPath == nil || cache.file(selectedPath ?? "") == nil {
                        selectedPath = files.first?.path
                    }
                }
                hasRead = true
            } catch {
                return
            }
        }
    }

    /// One commit's files, which the machine reads from that commit's own two trees. Held in no
    /// cache: a commit is immutable, so a reader who opens the same row twice is one request, and
    /// holding every commit's file list would be a page of them for a branch nobody is reviewing.
    private func refreshCommit(_ commit: BranchCommit, quietly: Bool, requestGeneration: Int) async {
        guard let session else { return }
        isLoading = !quietly
        defer {
            if requestGeneration == refreshGeneration { isLoading = false }
        }
        do {
            let result = try await session.perform(.commitFiles(sha: commit.sha))
            guard case .commitFiles(let records) = result else { return }
            guard requestGeneration == refreshGeneration, self.commit == commit else { return }
            if files != records {
                files = records
                generation += 1
            }
            hasRead = true
            problem = nil
            if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
                selectedPath = files.first?.path
            }
        } catch {
            guard requestGeneration == refreshGeneration, self.commit == commit else { return }
            problem = error.message
            hasRead = true
        }
    }

    /// One file's patch, read once per revision. Throws what the machine said, which is what the
    /// local read does with git's own message.
    func patch(for path: String) async throws -> String {
        guard let session else { throw CloudReviewFailure(message: "This Bloom Cloud workspace is closed.") }
        if let commit { return try await patch(for: path, in: commit) }
        let scope = wireScope
        var cache = caches[scope] ?? CloudReviewCache()
        if let held = cache.patch(for: path) { return held }
        do {
            let result = try await session.perform(.reviewPatch(path: path, scope: scope, knownRevision: cache.knownRevision(for: path)))
            guard case .reviewPatch(let record) = result else { return "" }
            let patch = cache.absorb(record, for: path)
            caches[scope] = cache
            return patch ?? ""
        } catch {
            throw CloudReviewFailure(message: error.message)
        }
    }

    /// One file's diff inside one commit, which is its own operation: a commit is two immutable
    /// trees and nothing the review measures continuously.
    ///
    /// Cached per commit for the life of this workspace, because a commit cannot change. The
    /// refusal a machine without the operation gives is turned into the sentence that says so;
    /// every other refusal is the machine's own words, since "this file did not change in that
    /// commit" is something a reader can act on and this Mac could not have worked out.
    private func patch(for path: String, in commit: BranchCommit) async throws -> String {
        guard let session else { throw CloudReviewFailure(message: "This Bloom Cloud workspace is closed.") }
        if let held = commitPatches[CommitFile(sha: commit.sha, path: path)] { return held }
        do {
            let result = try await session.perform(.commitPatch(sha: commit.sha, path: path))
            // No revision is ever sent for a commit, so the machine always sends the text back;
            // nil would mean "you already have this", which is not a thing this call can be told.
            guard case .reviewPatch(let record) = result, let patch = record.patch else { return "" }
            commitPatches[CommitFile(sha: commit.sha, path: path)] = patch
            return patch
        } catch {
            guard error.code == .invalidRequest else { throw CloudReviewFailure(message: error.message) }
            cannotReadCommitPatches = true
            throw CloudReviewFailure(message: Self.noCommitPatch)
        }
    }

    /// Drops the held patch for a file whose contents were rewritten under the reader.
    func forgetHeldDiff(for path: String) {
        for scope in caches.keys { caches[scope]?.forget(path: path) }
        presentations.forget(file: path)
        generation += 1
    }

    // MARK: What the pane last drew

    func heldDiff(for file: ChangedFile, ignoringWhitespace: Bool) -> DiffPresentation? {
        presentations.presentation(for: presentationKey(file, ignoringWhitespace: ignoringWhitespace))
    }

    func holdDiff(_ presentation: DiffPresentation, for file: ChangedFile, ignoringWhitespace: Bool) {
        presentations.store(presentation, for: presentationKey(file, ignoringWhitespace: ignoringWhitespace))
    }

    /// The machine's own name for the workspace stands in for the worktree path, which there is
    /// none of here: the key only has to tell one workspace's diffs from another's.
    private func presentationKey(_ file: ChangedFile, ignoringWhitespace: Bool) -> DiffPresentationCache.Key {
        DiffPresentationCache.Key(
            worktree: "cloud:" + (session?.id.rawValue ?? ""),
            base: session?.surfaceBaseBranch ?? "",
            file: file,
            scope: localScope,
            ignoresWhitespace: ignoringWhitespace
        )
    }

    /// Takes a file, or one hunk of it, back to what the review measured it against. Nil on
    /// success, or what the machine said. The machine does the git: it has the worktree.
    func revert(file: ChangedFile) async -> String? {
        guard let session else { return "This Bloom Cloud workspace is closed." }
        guard commit == nil else { return Self.commitIsMade }
        do {
            _ = try await session.perform(.revertFile(path: file.path, scope: wireScope))
        } catch {
            return error.message
        }
        forgetHeldDiff(for: file.path)
        await refresh()
        return nil
    }

    /// The hunk is sent as its own patch, because that is how the machine recognises it: a hunk
    /// that has moved or changed since this diff was read is refused there rather than guessed at.
    func discard(hunk: DiffHunk, of file: ChangedFile) async -> String? {
        guard let session else { return "This Bloom Cloud workspace is closed." }
        guard commit == nil else { return Self.commitIsMade }
        let whole: String
        do {
            whole = try await patch(for: file.path)
        } catch {
            return error.localizedDescription
        }
        guard let isolated = HunkPatch.isolate(hunk, from: whole) else {
            return "This part of the file has changed since it was read. Refresh the diff and try again."
        }
        do {
            _ = try await session.perform(.discardHunk(path: file.path, scope: wireScope, patch: isolated))
        } catch {
            return error.message
        }
        forgetHeldDiff(for: file.path)
        await refresh()
        return nil
    }

    private func loadPatchForSelection() async {
        guard let path = selectedPath else { return }
        _ = try? await patch(for: path)
    }

    func refreshFileTree(force: Bool) async {
        guard let session, !hasReadFileTree || force else { return }
        guard let result = try? await session.perform(.files), case .files(let paths) = result else { return }
        let index = FileTreeNode.index(paths)
        if fileTree != index { fileTree = index }
        hasReadFileTree = true
    }

    /// A file's text, when it has been read. Reading is asynchronous, so the first ask for a file
    /// answers nil and starts the read; the generation bump brings the pane back.
    func contents(of relativePath: String) -> String? {
        if let held = contentsByPath[relativePath] { return held }
        guard let session, contentsBeingRead.insert(relativePath).inserted else { return nil }
        Task {
            defer { contentsBeingRead.remove(relativePath) }
            guard let result = try? await session.perform(.file(path: relativePath)), case .file(let record) = result else { return }
            contentsByPath[relativePath] = record.text
            generation += 1
        }
        return nil
    }

    /// A file's text, waited for rather than polled. `contents(of:)` above answers what is held
    /// and starts a read; this is the same read for a caller that can wait for it.
    func text(of relativePath: String) async -> String? {
        if let held = contentsByPath[relativePath] { return held }
        guard let session else { return nil }
        guard let result = try? await session.perform(.file(path: relativePath)), case .file(let record) = result else { return nil }
        contentsByPath[relativePath] = record.text
        return record.text
    }

    // MARK: Read marks

    func isViewed(_ file: ChangedFile) -> Bool {
        guard let mark = viewed[file.path] else { return false }
        return mark == revision(of: file.path)
    }

    func setViewed(_ isViewed: Bool, file: ChangedFile) {
        if isViewed {
            viewed[file.path] = revision(of: file.path)
        } else {
            viewed.removeValue(forKey: file.path)
        }
        save()
    }

    func clearViewed() {
        viewed.removeAll()
        save()
    }

    var viewedSummary: String? {
        let files = files.map(ChangedFile.init(cloudRecord:))
        guard !files.isEmpty else { return nil }
        let ticked = files.filter(isViewed).count
        guard ticked > 0 else { return nil }
        return "\(ticked) of \(files.count) viewed"
    }

    /// What a read mark is measured against: the file's diff as the machine last described it, so
    /// the tick goes stale honestly when the agent edits the file again.
    private func revision(of path: String) -> String {
        files.first { $0.path == path }?.contentRevision ?? ""
    }

    private func save() {
        guard let session else { return }
        UserDefaults.standard.set(viewed, forKey: Self.viewedKey(session.id))
    }
}

/// One file inside one commit, which is what a commit patch is keyed by.
private struct CommitFile: Hashable {
    var sha: String
    var path: String
}

/// What a review read failed with, in the machine's own words.
struct CloudReviewFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

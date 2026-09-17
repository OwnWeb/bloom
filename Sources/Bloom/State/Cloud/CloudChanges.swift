import BloomClient
import BloomCore
import BloomProtocol
import Foundation
import Observation

/// What a Cloud workspace's review reads from its machine: the changed files, the patches, the
/// whole file list and the contents of a file, plus the read marks, which are this reader's own.
///
/// It is the Cloud half of `WorkspaceReviewSurface`, kept apart from the session for the reason
/// `WorkspaceModel` keeps its own review together: this is the only part of a workspace that is
/// read again and again while somebody scrolls, and it has caches (`CloudReviewCache`) that nothing
/// else should be able to reach into.
///
/// **Read when looked at and when the machine says something moved, never on a timer.** A long poll
/// would hold a request open on a machine that is trying to sleep; the `review` event the stream
/// already carries is the hint to read again, and it stops when the machine does.
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
    var inspectorTab: InspectorTab = .changes
    var showsAllFiles = false
    /// What the review pane last drew per file, so walking back to a file it has already read
    /// costs no request. The local model holds the same cache for the same reason.
    @ObservationIgnored private var presentations = DiffPresentationCache()
    /// Where a note is being written and which are open for editing, held for the protocol's sake.
    /// Nothing writes them today: `.reviewComments` is off for a Cloud workspace, so the gutter
    /// that would start one is not drawn.
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
    @ObservationIgnored private var contentsBeingRead: Set<String> = []
    /// Which files this reader has ticked, and what the file's diff looked like when they did.
    /// Kept on this Mac under the workspace's own key, because a read mark is one person's note to
    /// themselves; the local ones live in this Mac's database for the same reason.
    private var viewed: [String: String] = [:]

    init(session: CloudWorkspaceSession) {
        self.session = session
        viewed = (UserDefaults.standard.dictionary(forKey: Self.viewedKey(session.id)) as? [String: String]) ?? [:]
    }

    private static func viewedKey(_ id: CloudWorkspaceID) -> String { "cloud.viewedFiles.\(id.rawValue)" }

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

    /// A commit's files come over whole; its patches do not, so the diff pane says so rather than
    /// showing an empty one. The machine's `review_patch` measures the branch and the worktree,
    /// and a commit patch is the next thing to ask its builder for.
    static let noCommitPatch = "A commit's files are here. Its diff cannot be read from a Cloud"
        + " workspace yet."

    var scopeNote: String? {
        commit == nil ? nil : Self.noCommitPatch
    }

    func setScope(_ scope: BloomCore.DiffScope) {
        guard scope != localScope else { return }
        localScope = scope
        Task { await refresh() }
    }

    // MARK: Reading

    func refresh(quietly: Bool = false) async {
        guard let session else { return }
        if let commit { await refreshCommit(commit, quietly: quietly); return }
        let scope = wireScope
        var cache = caches[scope] ?? CloudReviewCache()
        if !quietly { isLoading = true }
        defer { isLoading = false }
        do {
            let result = try await session.perform(.reviewSnapshot(scope: scope, knownRevision: cache.revision, wait: false))
            guard case .reviewSnapshot(let snapshot) = result else { return }
            cache.absorb(snapshot)
            caches[scope] = cache
            guard scope == wireScope else { return }
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
            problem = error.message
            hasRead = true
        }
    }

    /// One commit's files, which the machine reads from that commit's own two trees. Held in no
    /// cache: a commit is immutable, so a reader who opens the same row twice is one request, and
    /// holding every commit's file list would be a page of them for a branch nobody is reviewing.
    private func refreshCommit(_ commit: BranchCommit, quietly: Bool) async {
        guard let session else { return }
        if !quietly { isLoading = true }
        defer { isLoading = false }
        do {
            let result = try await session.perform(.commitFiles(sha: commit.sha))
            guard case .commitFiles(let records) = result else { return }
            guard self.commit == commit else { return }
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
            problem = error.message
            hasRead = true
        }
    }

    /// One file's patch, read once per revision. Throws what the machine said, which is what the
    /// local read does with git's own message.
    func patch(for path: String) async throws -> String {
        guard let session else { throw CloudReviewFailure(message: "This Cloud workspace is closed.") }
        guard commit == nil else { throw CloudReviewFailure(message: Self.noCommitPatch) }
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
        guard let session else { return "This Cloud workspace is closed." }
        guard commit == nil else { return Self.noCommitPatch }
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
        guard let session else { return "This Cloud workspace is closed." }
        guard commit == nil else { return Self.noCommitPatch }
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

/// What a review read failed with, in the machine's own words.
struct CloudReviewFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

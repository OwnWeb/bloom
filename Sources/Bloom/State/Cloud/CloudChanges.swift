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
    /// workspace. `.commit` is a local-only scope until the machine's history lands, and is held
    /// here so the picker's selection survives being set.
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
    /// Which of the inspector's tabs this workspace is on, and whether its review is showing every
    /// file. The local model keeps the same two facts; they are per workspace and not per window.
    var inspectorTab: InspectorTab = .changes
    var showsAllFiles = false
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

    /// The scope the machine understands. A commit is not one of them yet, so the review falls
    /// back to the branch until the machine's history operation lands.
    private var wireScope: BloomProtocol.DiffScope {
        localScope == .uncommitted ? .uncommitted : .branch
    }

    var scopeNote: String? {
        guard case .commit = localScope else { return nil }
        return WorkspaceCapabilities.Capability.history.cloudSentence
    }

    func setScope(_ scope: BloomCore.DiffScope) {
        guard scope != localScope else { return }
        localScope = scope
        Task { await refresh() }
    }

    // MARK: Reading

    func refresh(quietly: Bool = false) async {
        guard let session else { return }
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

    /// One file's patch, read once per revision. Throws what the machine said, which is what the
    /// local read does with git's own message.
    func patch(for path: String) async throws -> String {
        guard let session else { throw CloudReviewFailure(message: "This Cloud workspace is closed.") }
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
        generation += 1
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

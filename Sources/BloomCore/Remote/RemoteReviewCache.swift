import BloomProtocol
import Foundation

/// One bounded cache shared by every client of the workspace. Concurrent readers share git work,
/// and a long-held read is told about a change without the file list being sent again.
///
/// #163 served many workspaces and kept a watch for each of the eight used most recently. This
/// server runs one, so it holds one watch; a workspace whose path changes (a restore into a new
/// folder) replaces it and drops everything cached for the old path. The patch cache stays
/// bounded by bytes and by count, because one branch can still hold thousands of changed files.
public actor RemoteReviewCache {
    struct Snapshot: Sendable {
        var revision: String
        var files: [ChangedFile]
        /// Per path. Kept here rather than on `ChangedFile`, because it names a diff at one base
        /// and the Mac's type has no reason to carry it.
        var contentRevisions: [String: String]
        var base: String
        var watchedGeneration: UInt64
        var built: ContinuousClock.Instant

        var records: [ChangedFileRecord] {
            files.map { $0.record(contentRevision: contentRevisions[$0.path]) }
        }
    }

    struct Key: Hashable {
        var path: String
        var base: String
        var scope: BloomProtocol.DiffScope

        init(workspace: Workspace, scope: BloomProtocol.DiffScope) {
            path = workspace.path
            base = workspace.baseBranch
            self.scope = scope
        }
    }

    struct PatchKey: Hashable {
        var key: Key
        var path: String
        var revision: String
    }

    public struct Metrics: Sendable {
        public var scans = 0
        public var patchBuilds = 0
        public var patchHits = 0
        public var retainedPatchBytes = 0
    }

    public private(set) var metrics = Metrics()
    private var watch: (path: String, watch: RemoteReviewWatch)?
    private var watchTasks: [String: Task<RemoteReviewWatch, Error>] = [:]
    private var snapshots: [Key: Snapshot] = [:]
    private var scans: [Key: Task<Snapshot, Error>] = [:]
    private var patches: [PatchKey: String] = [:]
    private var patchOrder: [PatchKey] = []
    private var patchTasks: [PatchKey: Task<String, Error>] = [:]
    private let workers = RemoteReviewWorkers()
    private var closed = false
    private let patchBudget: Int
    private let patchCountLimit = 128
    private let backstop: Duration
    private let resolveRoots: @Sendable (Workspace) async throws -> [String]
    private var shutdownTask: Task<Void, Never>?
    /// Whether the worktree is a whole checkout, and so whether anything read from it is true.
    ///
    /// **A diff taken while `git clone` is still writing the checkout is a lie that looks exactly
    /// like an answer.** Seen on a Runner on 23 September 2026: `HEAD` existed and the index was
    /// half written, so the branch comparison listed all 5,107 tracked files as deleted, and this
    /// cache kept that answer until its watcher next moved. So nothing is read until the machine's
    /// setup says the clone finished, and the refusal says why rather than handing back an empty
    /// or a bogus list. True everywhere that is not a machine, where nothing is cloned.
    public private(set) var isWorktreeCloned: Bool
    /// Moved every time `isWorktreeCloned` is set. A scan, a watch or a patch begun under one
    /// epoch and finishing under another was read from a worktree that has since been remade, so
    /// it is neither kept nor returned.
    private var worktreeEpoch: UInt64 = 0

    public init(backstop: Duration = .seconds(30), patchBudget: Int = 32 * 1_024 * 1_024, worktreeCloned: Bool = true) {
        self.backstop = backstop
        self.patchBudget = max(0, patchBudget)
        resolveRoots = Self.gitRoots
        isWorktreeCloned = worktreeCloned
    }

    init(backstop: Duration = .seconds(30), worktreeCloned: Bool = true,
         resolveRoots: @escaping @Sendable (Workspace) async throws -> [String]) {
        self.backstop = backstop
        patchBudget = 32 * 1_024 * 1_024
        self.resolveRoots = resolveRoots
        isWorktreeCloned = worktreeCloned
    }

    private static func gitRoots(_ workspace: Workspace) async throws -> [String] {
        let output = try await Git.check(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: workspace.path)
        return [workspace.path] + output.stdout.split(separator: "\n").map(String.init)
    }

    private static let closedFailure = RemoteFailure(.unavailable, "The review connection closed.")

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw Self.closedFailure }
    }

    /// What a client is told while the repository is still being cloned. `workspace_changing` is
    /// the code the protocol already has for "being set up or archived", so a client that has never
    /// heard of this refusal still reads it as a wait rather than as git failing.
    static let cloningFailure = RemoteFailure(
        .workspaceChanging,
        "This Bloom Cloud workspace is still cloning its repository, so there are no changes to read yet."
    )

    private func requireCloned(since epoch: UInt64? = nil) throws {
        guard isWorktreeCloned, epoch.map({ $0 == worktreeEpoch }) ?? true else { throw Self.cloningFailure }
    }

    /// The machine's setup saying a clone has begun, or has finished. Everything held is forgotten
    /// either way, the watch included, because its roots were resolved against a repository that
    /// is about to be deleted or was not whole yet.
    public func worktreeChanged(cloned: Bool) {
        guard !closed else { return }
        isWorktreeCloned = cloned
        worktreeEpoch &+= 1
        watch?.watch.stop()
        watch = nil
        snapshots.removeAll()
        for key in patchOrder { removePatch(key) }
    }

    /// The changed files, or nil files when `knownRevision` is still current. With `wait`, a
    /// caller that already has the current revision is held for up to fifteen seconds in case it
    /// moves, which is what lets a client follow changes without polling git.
    public func snapshot(
        workspace: Workspace, scope: BloomProtocol.DiffScope, knownRevision: String? = nil, wait: Bool = false
    ) async throws -> ReviewSnapshotRecord {
        let deadline = ContinuousClock.now + .seconds(wait ? 15 : 0)
        while true {
            try requireOpen()
            let value = try await current(workspace: workspace, scope: scope)
            try requireOpen()
            if value.revision != knownRevision { return ReviewSnapshotRecord(revision: value.revision, files: value.records) }
            if ContinuousClock.now >= deadline { return ReviewSnapshotRecord(revision: value.revision, files: nil) }
            // Checking an in-memory notification counter does no filesystem or git work.
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func watcher(for workspace: Workspace) async throws -> RemoteReviewWatch {
        if let held = watch, held.path == workspace.path { return held.watch }
        let epoch = worktreeEpoch
        let task: Task<RemoteReviewWatch, Error>
        var created = false
        if let pending = watchTasks[workspace.path] {
            task = pending
        } else {
            created = true
            task = Task { [resolveRoots] in
                try Task.checkCancellation()
                let roots = try await resolveRoots(workspace)
                try Task.checkCancellation()
                return RemoteReviewWatch(roots: Array(Set(roots)))
            }
            watchTasks[workspace.path] = task
        }
        defer { if created { watchTasks[workspace.path] = nil } }
        let made = try await task.value
        do {
            try requireOpen()
            try requireCloned(since: epoch)
        } catch {
            if closed || epoch != worktreeEpoch { made.stop() }
            throw error
        }
        if let held = watch {
            if held.path == workspace.path { return held.watch }
            held.watch.stop()
            snapshots = snapshots.filter { $0.key.path == workspace.path }
            for key in patchOrder where key.key.path != workspace.path { removePatch(key) }
        }
        watch = (workspace.path, made)
        return made
    }

    private func current(workspace: Workspace, scope: BloomProtocol.DiffScope) async throws -> Snapshot {
        try requireOpen()
        try requireCloned()
        let epoch = worktreeEpoch
        let key = Key(workspace: workspace, scope: scope)
        // A base branch that changed leaves the old entry for this scope unreachable; drop it.
        snapshots = snapshots.filter { $0.key.scope != key.scope || $0.key == key }
        let watch = try await watcher(for: workspace)
        try requireOpen()
        let age = watch.isReliable ? backstop : .seconds(2)
        if let held = snapshots[key], held.watchedGeneration == watch.generation, held.built.duration(to: .now) < age { return held }
        if let task = scans[key] {
            let value = try await task.value
            try requireOpen()
            try requireCloned(since: epoch)
            return value
        }
        let generation = watch.generation
        metrics.scans += 1
        let task = Task {
            try Task.checkCancellation()
            let base = try await RemoteReview.base(workspace: workspace, scope: scope)
            let files = try await RemoteReview.changes(workspace: workspace, base: base, scope: scope)
            var revisions: [String: String] = [:]
            for file in files { revisions[file.path] = Self.fileRevision(file, workspace: workspace, base: base) }
            var snapshot = Snapshot(revision: "", files: files, contentRevisions: revisions, base: base,
                                    watchedGeneration: generation, built: .now)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            snapshot.revision = RemoteFileOperations.revision(try encoder.encode(snapshot.records) + Data(base.utf8))
            return snapshot
        }
        scans[key] = task
        defer { scans[key] = nil }
        let value = try await task.value
        try requireOpen()
        try requireCloned(since: epoch)
        // An event received while git was reading is consumed by the next scan, never lost.
        if watch.generation == generation { snapshots[key] = value }
        return value
    }

    static func fileRevision(_ file: ChangedFile, workspace: Workspace, base: String) -> String {
        var data = Data((base + "\0" + file.path + "\0" + (file.oldPath ?? "") + "\0" + file.change.rawValue).utf8)
        for path in [file.path, file.oldPath].compactMap({ $0 }) {
            data.append(RemoteReviewFileStamp.read(URL(fileURLWithPath: workspace.path).appendingPathComponent(path).path))
        }
        return RemoteFileOperations.revision(data)
    }

    /// One file's patch, or a nil patch when `knownRevision` is still current.
    public func patch(
        workspace: Workspace, path: String, scope: BloomProtocol.DiffScope, knownRevision: String? = nil
    ) async throws -> PatchSnapshotRecord {
        try RemoteReview.validateRelativePath(path)
        let key = Key(workspace: workspace, scope: scope)
        for _ in 0..<3 {
            let value = try await current(workspace: workspace, scope: scope)
            try requireOpen()
            let epoch = worktreeEpoch
            guard let file = value.files.first(where: { $0.path == path }), let revision = value.contentRevisions[path] else {
                throw RemoteFailure.notFound("This file no longer has changes. Refresh the file list.")
            }
            if Self.fileRevision(file, workspace: workspace, base: value.base) != revision {
                snapshots[key] = nil
                continue
            }
            if knownRevision == revision { return PatchSnapshotRecord(revision: revision, patch: nil) }
            let patchKey = PatchKey(key: key, path: path, revision: revision)
            if let held = patches[patchKey] {
                metrics.patchHits += 1
                patchOrder.removeAll { $0 == patchKey }
                patchOrder.append(patchKey)
                return PatchSnapshotRecord(revision: revision, patch: held)
            }
            let task: Task<String, Error>
            if let pending = patchTasks[patchKey] {
                task = pending
            } else {
                metrics.patchBuilds += 1
                task = Task { [workers] in
                    try await workers.acquire()
                    do {
                        try Task.checkCancellation()
                        let text = try await RemoteReview.patch(workspace: workspace, file: file, base: value.base, scope: scope)
                        await workers.release()
                        return text
                    } catch {
                        await workers.release()
                        throw error
                    }
                }
                patchTasks[patchKey] = task
            }
            let text: String
            do { text = try await task.value } catch {
                patchTasks[patchKey] = nil
                throw error
            }
            patchTasks[patchKey] = nil
            try requireOpen()
            try requireCloned(since: epoch)
            guard Self.fileRevision(file, workspace: workspace, base: value.base) == revision else {
                snapshots[key] = nil
                continue
            }
            if patches[patchKey] == nil {
                patches[patchKey] = text
                patchOrder.append(patchKey)
                metrics.retainedPatchBytes += text.utf8.count
            }
            while metrics.retainedPatchBytes > patchBudget || patchOrder.count > patchCountLimit {
                removePatch(patchOrder[0])
            }
            return PatchSnapshotRecord(revision: revision, patch: text)
        }
        throw RemoteFailure(.conflict, "This file is changing. Try opening its diff again.")
    }

    private func removePatch(_ key: PatchKey) {
        metrics.retainedPatchBytes -= patches.removeValue(forKey: key)?.utf8.count ?? 0
        patchOrder.removeAll { $0 == key }
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        closed = true
        let watchesInFlight = Array(watchTasks.values)
        let scansInFlight = Array(scans.values)
        let patchesInFlight = Array(patchTasks.values)
        watch?.watch.stop()
        watch = nil
        for task in watchesInFlight { task.cancel() }
        for task in scansInFlight { task.cancel() }
        for task in patchesInFlight { task.cancel() }
        snapshots.removeAll()
        patches.removeAll()
        patchOrder.removeAll()
        metrics.retainedPatchBytes = 0
        // A cancelled git read can still be unwinding. Shutdown waits until every child has
        // finished, and callers also check `closed` again before publishing a result or a watch.
        let task = Task {
            for pending in watchesInFlight { if let made = try? await pending.value { made.stop() } }
            for pending in scansInFlight { _ = try? await pending.value }
            for pending in patchesInFlight { _ = try? await pending.value }
        }
        shutdownTask = task
        await task.value
    }
}

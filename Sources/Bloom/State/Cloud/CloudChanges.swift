import BloomClient
import BloomCore
import BloomProtocol
import Observation

/// A Cloud workspace's changes, for its Changes pane: the files, by scope, and the patch of the one
/// being read.
///
/// **Read when looked at and when the machine says something moved, never on a timer.** A long
/// poll would be simpler and would hold a request open on a machine that is trying to sleep; the
/// `review` event the stream already carries is the hint to read again, and it stops when the
/// machine does.
@MainActor
@Observable
final class CloudChanges {
    var scope: BloomProtocol.DiffScope = .branch {
        didSet { if scope != oldValue { Task { await refresh() } } }
    }
    private(set) var files: [ChangedFileRecord] = []
    var selectedPath: String? {
        didSet { if selectedPath != oldValue { Task { await loadPatch() } } }
    }
    private(set) var diff: FileDiff?
    private(set) var isLoading = false
    private(set) var problem: String?

    @ObservationIgnored private weak var session: CloudWorkspaceSession?
    @ObservationIgnored private var caches: [BloomProtocol.DiffScope: CloudReviewCache] = [:]

    init(session: CloudWorkspaceSession) {
        self.session = session
    }

    func refresh() async {
        guard let session else { return }
        let scope = scope
        var cache = caches[scope] ?? CloudReviewCache()
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await session.perform(.reviewSnapshot(scope: scope, knownRevision: cache.revision, wait: false))
            guard case .reviewSnapshot(let snapshot) = result else { return }
            cache.absorb(snapshot)
            caches[scope] = cache
            guard scope == self.scope else { return }
            files = cache.files
            problem = nil
            if selectedPath == nil || cache.file(selectedPath ?? "") == nil {
                selectedPath = files.first?.path
            } else {
                await loadPatch()
            }
        } catch {
            problem = error.message
        }
    }

    private func loadPatch() async {
        guard let session, let path = selectedPath else {
            diff = nil
            return
        }
        let scope = scope
        var cache = caches[scope] ?? CloudReviewCache()
        if let held = cache.patch(for: path) {
            diff = DiffParser.parse(held).first
            return
        }
        do {
            let result = try await session.perform(.reviewPatch(path: path, scope: scope, knownRevision: cache.knownRevision(for: path)))
            guard case .reviewPatch(let record) = result else { return }
            let patch = cache.absorb(record, for: path)
            caches[scope] = cache
            guard path == selectedPath, scope == self.scope else { return }
            diff = patch.flatMap { DiffParser.parse($0).first }
        } catch {
            problem = error.message
        }
    }
}

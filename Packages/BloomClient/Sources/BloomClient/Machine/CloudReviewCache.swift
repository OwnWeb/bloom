import BloomProtocol
import Foundation

/// A Cloud workspace's changed files and the patches already read, per scope.
///
/// **Nothing is read twice.** A snapshot asked with the revision already held comes back without
/// its files, and a patch asked with the `content_revision` it was read at comes back without the
/// patch, so a review that refreshes on every `review` event costs a few bytes when nothing moved.
/// That only works if the revisions sent are exactly the ones the held values were read at, which
/// is what this keeps.
public struct CloudReviewCache: Sendable, Hashable {
    public private(set) var revision: String?
    public private(set) var files: [ChangedFileRecord] = []
    private var patches: [String: (revision: String, patch: String)] = [:]

    public init() {}

    public static func == (lhs: CloudReviewCache, rhs: CloudReviewCache) -> Bool {
        lhs.revision == rhs.revision && lhs.files == rhs.files && lhs.patches.mapValues(\.revision) == rhs.patches.mapValues(\.revision)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(revision)
        hasher.combine(files)
    }

    /// Folds a snapshot in. Patches for files that left, or whose content moved, are dropped.
    public mutating func absorb(_ snapshot: ReviewSnapshotRecord) {
        guard let files = snapshot.files else {
            revision = snapshot.revision
            return
        }
        revision = snapshot.revision
        self.files = files
        let current = Dictionary(files.map { ($0.path, $0.contentRevision) }, uniquingKeysWith: { first, _ in first })
        patches = patches.filter { path, held in current[path] == .some(held.revision) }
    }

    /// The revision to send for a file's patch: the one its held patch was read at, if that is
    /// still the file's current one.
    public func knownRevision(for path: String) -> String? {
        guard let held = patches[path], file(path)?.contentRevision == held.revision else { return nil }
        return held.revision
    }

    public func patch(for path: String) -> String? {
        guard knownRevision(for: path) != nil else { return nil }
        return patches[path]?.patch
    }

    /// Folds a patch answer in. Answers the patch to draw: the new one, or the held one when the
    /// machine said it had not moved.
    @discardableResult
    public mutating func absorb(_ record: PatchSnapshotRecord, for path: String) -> String? {
        if let patch = record.patch {
            patches[path] = (record.revision, patch)
            return patch
        }
        return patches[path].flatMap { $0.revision == record.revision ? $0.patch : nil }
    }

    public func file(_ path: String) -> ChangedFileRecord? {
        files.first { $0.path == path }
    }
}

import Foundation

/// One changed file.
///
/// `change` is git's letter spelled out: `added`, `modified`, `deleted`, `renamed`, `copied` or
/// `untracked`. `content_revision` changes whenever the file's diff could have, and is what a
/// client hands back to `review_patch` to be told nothing moved.
public struct ChangedFileRecord: Codable, Sendable, Hashable {
    public var path: String
    public var oldPath: String?
    public var change: String
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    public var contentRevision: String?
    /// Which staging layer this change is in, when the scope separates them: `staged`, `unstaged`,
    /// `untracked` or `conflicted`. Nil for the branch comparison, which has no layers.
    public var layer: String?

    public init(path: String, oldPath: String? = nil, change: String, additions: Int, deletions: Int, isBinary: Bool,
                contentRevision: String? = nil, layer: String? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.contentRevision = contentRevision
        self.layer = layer
    }

    enum CodingKeys: String, CodingKey {
        case path, change, additions, deletions, layer
        case oldPath = "old_path"
        case isBinary = "is_binary"
        case contentRevision = "content_revision"
    }
}

/// The changed files at a revision. `files` is nil when the caller already had this revision.
public struct ReviewSnapshotRecord: Codable, Sendable, Hashable {
    public var revision: String
    public var files: [ChangedFileRecord]?

    public init(revision: String, files: [ChangedFileRecord]?) {
        self.revision = revision
        self.files = files
    }
}

/// One file's diff at a revision. `patch` is nil when the caller already had this revision.
public struct PatchSnapshotRecord: Codable, Sendable, Hashable {
    public var revision: String
    public var patch: String?

    public init(revision: String, patch: String?) {
        self.revision = revision
        self.patch = patch
    }
}

/// A text file and the revision a write has to name to replace it.
public struct TextFileRecord: Codable, Sendable, Hashable {
    public var path: String
    public var text: String
    public var revision: String

    public init(path: String, text: String, revision: String) {
        self.path = path
        self.text = text
        self.revision = revision
    }
}

/// A file's bytes, base64 in JSON.
public struct DownloadRecord: Codable, Sendable, Hashable {
    public var path: String
    public var data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

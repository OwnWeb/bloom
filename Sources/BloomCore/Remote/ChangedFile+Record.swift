import BloomProtocol
import Foundation

extension ChangedFile {
    /// The file as the wire carries it. The content revision is the review cache's, never the
    /// file's own, because it names the file's diff at one base and not the file.
    public func record(contentRevision: String?) -> ChangedFileRecord {
        ChangedFileRecord(
            path: path, oldPath: oldPath, change: change.wireName,
            additions: additions, deletions: deletions, isBinary: isBinary, contentRevision: contentRevision
        )
    }
}

extension ChangedFile.Change {
    /// Git's letter spelled out, so a reader in another language does not have to know git.
    public var wireName: String {
        switch self {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .untracked: "untracked"
        }
    }
}

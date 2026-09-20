import BloomProtocol
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// File mutations resolve against the workspace's worktree and use an optimistic revision check.
/// A client never hands a path to a file writer of its own.
public enum RemoteFileOperations {
    public static let transferLimit = 8_388_608

    /// The revision a text file read hands out and a write has to name.
    public static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func write(workspace: Workspace, path: String, text: String, revision expected: String) throws -> TextFileRecord {
        guard text.utf8.count <= RemoteReview.fileLimit else {
            throw RemoteFailure(.tooLarge, "Text files larger than 2 MB cannot be edited here.")
        }
        let data = Data(text.utf8)
        // **An empty revision means "only if there is no file yet"**: no file has one, so it cannot
        // be mistaken for a stale read. It is how a client adds a settings file a project does not
        // have, and it refuses to overwrite one that appeared meanwhile, as a stale revision does.
        guard !expected.isEmpty else {
            do {
                _ = try WorkspaceFileAccess(workspace: workspace, path: path, creatingParents: true, writing: true).create(data, mode: 0o644)
            } catch let failure as RemoteFailure where failure.code == .conflict {
                throw RemoteFailure(.conflict, "This file exists already. Reload it and save your change into it.")
            }
            return TextFileRecord(path: path, text: text, revision: revision(data))
        }
        try WorkspaceFileAccess(workspace: workspace, path: path, writing: true).replace(data, expectedRevision: expected, limit: RemoteReview.fileLimit)
        return TextFileRecord(path: path, text: text, revision: revision(data))
    }

    public static func download(workspace: Workspace, path: String) throws -> DownloadRecord {
        let data = try WorkspaceFileAccess(workspace: workspace, path: path).read(limit: transferLimit)
        return DownloadRecord(path: path, data: data)
    }

    static func validateUpload(name: String, data: Data) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 240 else {
            throw RemoteFailure.invalid("Choose a file up to 8 MB with a valid filename.")
        }
        guard data.count <= transferLimit else {
            throw RemoteFailure(.tooLarge, "Choose a file up to 8 MB with a valid filename.")
        }
    }

    /// Copies a file into the workspace's attachment folder and answers the path an agent reads
    /// it from, relative to the worktree.
    public static func upload(workspace: Workspace, name: String, data: Data) throws -> String {
        try validateUpload(name: name, data: data)
        let path = "\(WorktreeScratch.attachments)/\(UUID().uuidString)/\(name)"
        // The same shield `WorktreeScratch.shield` lays down, written through the descriptor walk
        // so an attachment folder swapped for a symlink cannot put it somewhere else.
        try WorkspaceFileAccess(workspace: workspace, path: WorktreeScratch.attachments + "/.gitignore", creatingParents: true)
            .create(Data("*\n".utf8), allowExisting: true)
        try WorkspaceFileAccess(workspace: workspace, path: path, creatingParents: true).create(data)
        return path
    }
}

import Foundation

/// Directory entries Git cannot name, including empty and ignored folders.
///
/// The All files tree still asks Git for its files. This walk adds folders with no files beneath
/// them, while leaving Git's internal directories out of a listing of worktree content.
public enum FileTreeDirectoryListing {
    public static func paths(in worktree: String) -> [String] {
        let root = URL(fileURLWithPath: worktree, isDirectory: true).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys)
        ) else { return [] }

        var paths: [String] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard url.path.hasPrefix(prefix) else { continue }
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            paths.append(String(url.path.dropFirst(prefix.count)) + "/")
        }
        return paths
    }
}

import BloomProtocol
import Foundation

/// `search_code` on a machine: the Mac's code search, over the files `files` lists, read the way
/// every other file on a machine is read.
///
/// **Not `SourceSearch` itself, and the difference is the reading.** That one resolves a path's
/// symlinks and then opens what it found, which is right on a Mac where the reader owns the disk.
/// Here the reader is anybody with `view`, so each file goes through `WorkspaceFileAccess`, whose
/// descriptor walk refuses a path that leaves the worktree at the moment it is opened, a symlink
/// swapped in between included. The matching is the Mac's: case-insensitive, one match per line,
/// files over 1 MB and anything binary or not UTF-8 left out.
///
/// **Bounded three ways**, because a query costs every file in the worktree: at most `limit`
/// matches (200 at most), a query of at most 256 characters, and ten seconds of reading, after
/// which what was found is answered with `truncated`. The query is only ever compared with text; no
/// process is started, so there is no command line for it to be mistaken for a flag on.
enum RemoteCodeSearch {
    static let fileLimit = 1_048_576
    static let maximumMatches = 200
    static let queryLimit = 256
    static let lineLimit = 400
    /// A cap on a worktree too big to read in one go, not a measurement of one.
    static let timeLimit: Duration = .seconds(10)

    static func search(
        workspace: Workspace, paths: [String], query: String, limit: Int?, clock: ContinuousClock = ContinuousClock()
    ) throws -> OperationResult {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle.count <= queryLimit else {
            throw RemoteFailure.invalid("Search for something between 1 and \(queryLimit) characters.")
        }
        let cap = min(max(limit ?? maximumMatches, 1), maximumMatches)
        let deadline = clock.now.advanced(by: timeLimit)
        var found: [CodeMatchRecord] = []
        for path in paths {
            try Task.checkCancellation()
            if clock.now >= deadline { return .codeMatches(matches: found, truncated: true) }
            guard let data = try? WorkspaceFileAccess(workspace: workspace, path: path).read(limit: fileLimit),
                  !data.contains(0), let text = String(data: data, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                guard let range = line.range(of: needle, options: .caseInsensitive) else { continue }
                found.append(CodeMatchRecord(path: path, line: index + 1, column: NSRange(range, in: line).location + 1,
                                             text: String(line.prefix(lineLimit))))
                if found.count >= cap { return .codeMatches(matches: found, truncated: true) }
            }
        }
        return .codeMatches(matches: found, truncated: false)
    }
}

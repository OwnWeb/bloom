import BloomProtocol
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Review reads for the one workspace this server runs. A client names a scope and a path and
/// nothing else: it cannot supply a git revision, pretend a tracked file is untracked, or resolve
/// a path on its own machine.
///
/// The file list is read here rather than through `Git.changedFiles`, for three reasons that are
/// all about a reader on the other side of a network. The Mac's uncommitted scope splits a file
/// into staged and unstaged rows, and the wire record has no layer to tell those apart, so here
/// uncommitted is one row per path measured from `HEAD`. The Mac counts an untracked symlink by
/// reading whatever it points at, which on a server is a way to learn the line count of a file
/// outside the worktree. And the Mac reads an untracked file whole however large it is, where a
/// server has to stop at `fileLimit`. The parsers are still git's own, shared with the Mac.
public enum RemoteReview {
    public static let fileLimit = 2_097_152

    public static func changes(workspace: Workspace, scope: BloomProtocol.DiffScope) async throws -> [ChangedFile] {
        let base = try await base(workspace: workspace, scope: scope)
        return try await changes(workspace: workspace, base: base, scope: scope)
    }

    /// What a scope measures from, resolved now. The branch scope is the merge base the Mac's
    /// inspector uses; the other three are all measured from `HEAD`, and differ in which side of
    /// the index they compare with.
    static func base(workspace: Workspace, scope: BloomProtocol.DiffScope) async throws -> String {
        switch scope {
        case .branch: try await Git.baseline(workspace.baseBranch, in: workspace.path)
        case .uncommitted, .staged, .unstaged: try await Git.check(["rev-parse", "--verify", "HEAD"], in: workspace.path).trimmed
        }
    }

    /// The `git diff` arguments a scope is, and whether files git has never seen belong in it.
    ///
    /// Staged is HEAD to the index, which is what a commit would take; unstaged is the index to the
    /// worktree, which is what a commit would leave behind. Untracked files are in neither the
    /// index nor a commit, so they sit with the unstaged side, and never with the staged one.
    static func comparison(scope: BloomProtocol.DiffScope, base: String) -> (arguments: [String], includesUntracked: Bool) {
        switch scope {
        case .branch, .uncommitted: ([base], true)
        case .staged: (["--cached", base], false)
        case .unstaged: ([], true)
        }
    }

    static func changes(workspace: Workspace, base: String,
                        scope: BloomProtocol.DiffScope = .branch) async throws -> [ChangedFile] {
        let worktree = workspace.path
        let comparison = comparison(scope: scope, base: base)
        async let nameStatusRead = Git.checkRaw(
            ["diff", "--no-ext-diff", "--no-textconv", "--name-status", "-M", "-z"] + comparison.arguments + ["--"], in: worktree
        )
        async let numstatRead = Git.checkRaw(
            ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-M", "-z"] + comparison.arguments + ["--"], in: worktree
        )
        async let untrackedRead = Git.checkRaw(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree)

        let changeByPath = Git.parseNameStatus(try await nameStatusRead.stdout)
        var byPath = Git.parseNumstat(try await numstatRead.stdout, changes: changeByPath)
        // The layer is the scope's, since these scopes are the layers: a client showing staged and
        // unstaged side by side reads it rather than working it out from which call it made.
        let layer: ChangeLayer? = switch scope {
        case .staged: .staged
        case .unstaged: .unstaged
        case .branch, .uncommitted: nil
        }
        if let layer {
            for (path, file) in byPath {
                var file = file
                file.layer = layer
                byPath[path] = file
            }
        }
        for record in comparison.includesUntracked ? Git.nulRecords(try await untrackedRead.stdout) : [] {
            let path = String(decoding: record, as: UTF8.self)
            guard !path.isEmpty, byPath[path] == nil else { continue }
            let summary = untrackedSummary(path: path, worktree: worktree)
            byPath[path] = ChangedFile(
                path: path, change: .untracked, additions: summary.additions, isBinary: summary.isBinary
            )
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    /// Counted the way git counts, without following a link and without reading past the limit.
    /// Git records a symlink as the spelling of its target, which is one line. A file over the
    /// limit is reported with no count rather than as binary, because it is not binary, it is only
    /// too large to open here.
    private static func untrackedSummary(path: String, worktree: String) -> (additions: Int, isBinary: Bool) {
        let full = URL(fileURLWithPath: worktree).appendingPathComponent(path).path
        var info = stat()
        guard lstat(full, &info) == 0 else { return (0, false) }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? ""
            return (Git.countLines(target), false)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= fileLimit,
              let data = try? WorkspaceFileAccess(root: worktree, path: path).read(limit: fileLimit) else {
            return (0, false)
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return (0, true) }
        return (Git.countLines(text), false)
    }

    public static func patch(workspace: Workspace, path: String, scope: BloomProtocol.DiffScope) async throws -> String {
        try validateRelativePath(path)
        let base = try await base(workspace: workspace, scope: scope)
        // The scope's own list, not the whole comparison's. A file staged and then put back in the
        // worktree is in the staged list and in no other, so looking it up in the wrong one answers
        // "no changes in the selected scope" about a file the client is looking at.
        let files = try await changes(workspace: workspace, base: base, scope: scope)
        guard let file = files.first(where: { $0.path == path }) else {
            throw RemoteFailure.notFound("This file has no changes in the selected scope. Refresh the file list.")
        }
        return try await patch(workspace: workspace, file: file, base: base, scope: scope)
    }

    static func patch(workspace: Workspace, file: ChangedFile, base: String,
                      scope: BloomProtocol.DiffScope = .branch) async throws -> String {
        let path = file.path
        try validateRelativePath(path)
        let arguments: [String]
        if file.change == .untracked {
            // Git reads symlinks as links. The text file read separately refuses escapes.
            arguments = ["--literal-pathspecs", "diff", "--no-index", "--no-ext-diff", "--no-textconv",
                         "--no-color", "--", "/dev/null", path]
        } else {
            let oldPath = file.oldPath ?? path
            try validateRelativePath(oldPath)
            let oldSize = try await Git.run(["cat-file", "-s", "\(base):\(oldPath)"], in: workspace.path, timeout: .seconds(10))
            if oldSize.ok, let bytes = Int(oldSize.trimmed), bytes > fileLimit {
                throw RemoteFailure(.tooLarge, "The original file is larger than 2 MB. Review it on the server.")
            }
            arguments = ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "-M"]
                + comparison(scope: scope, base: base).arguments + ["--"] + (file.oldPath.map { [$0, path] } ?? [path])
        }
        let paths = file.oldPath.map { [$0, path] } ?? [path]
        let snapshot = try RemoteDiffWorktree(workspace: workspace, paths: paths)
        defer { snapshot.remove() }
        let result = try await Git.run(snapshot.arguments(arguments, workspace: workspace), in: snapshot.path, timeout: .seconds(20))
        guard result.ok || (file.change == .untracked && result.status == 1) else {
            throw Git.error(arguments, result.status, result.stderr, result.stdout)
        }
        guard result.stdout.utf8.count <= fileLimit else {
            throw RemoteFailure(.tooLarge, "This diff is larger than 2 MB. Review it on the server.")
        }
        return result.stdout
    }

    public static func file(workspace: Workspace, path: String) throws -> TextFileRecord {
        try validateRelativePath(path)
        let data = try WorkspaceFileAccess(workspace: workspace, path: path).read(limit: fileLimit)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw RemoteFailure.invalid("This file is binary or is not UTF-8 text.")
        }
        return TextFileRecord(path: path, text: text, revision: RemoteFileOperations.revision(data))
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else {
            throw RemoteFailure.invalid("Use a relative path inside this workspace.")
        }
    }
}

import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

@Suite("search_code on a machine", .scratchDirectory)
struct RemoteCodeSearchTests {
    private func worktree() throws -> Workspace {
        let root = TestScratch.unique("code-search"), outside = TestScratch.unique("code-search-outside")
        for path in [root + "/app", outside] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        try "let retryAfter = 90\n".write(toFile: root + "/app/Queue.swift", atomically: true, encoding: .utf8)
        try "unrelated\nRETRYAFTER: 30\n".write(toFile: root + "/config.yml", atomically: true, encoding: .utf8)
        try Data([0x72, 0x65, 0x74, 0x72, 0x79, 0x00]).write(to: URL(fileURLWithPath: root + "/binary.dat"))
        try "retryAfter is a secret out here\n".write(toFile: outside + "/secret.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/escape.txt", withDestinationPath: outside + "/secret.txt")
        return Workspace(repoID: .new(), name: "Search", branch: "main", path: root, baseBranch: "main")
    }

    private let paths = ["app/Queue.swift", "binary.dat", "config.yml", "escape.txt"]

    private func matches(_ result: OperationResult) throws -> (matches: [CodeMatchRecord], truncated: Bool) {
        guard case .codeMatches(let matches, let truncated) = result else { throw RemoteFailure(.internal, "not code_matches") }
        return (matches, truncated)
    }

    /// **Inside the worktree, whatever a path points at.** A symlink to a file outside is listed
    /// like any other path and is never read, because the file is opened without following it.
    @Test("it matches case-insensitively, and never reads through a link out of the worktree or a binary file")
    func searching() throws {
        let workspace = try worktree()
        let found = try matches(RemoteCodeSearch.search(workspace: workspace, paths: paths, query: "retryafter", limit: nil))
        #expect(found.matches.map(\.path) == ["app/Queue.swift", "config.yml"])
        #expect(found.matches.first == CodeMatchRecord(path: "app/Queue.swift", line: 1, column: 5, text: "let retryAfter = 90"))
        #expect(found.matches.last?.line == 2)
        #expect(!found.truncated)
    }

    @Test("results stop at the limit and say so, and an empty or over-long query is refused")
    func bounds() throws {
        let workspace = try worktree()
        let capped = try matches(RemoteCodeSearch.search(workspace: workspace, paths: paths, query: "retryafter", limit: 1))
        #expect(capped.matches.count == 1)
        #expect(capped.truncated)
        #expect(throws: RemoteFailure.self) { try RemoteCodeSearch.search(workspace: workspace, paths: paths, query: "  ", limit: nil) }
        #expect(throws: RemoteFailure.self) {
            try RemoteCodeSearch.search(workspace: workspace, paths: paths, query: String(repeating: "a", count: 257), limit: nil)
        }
    }
}

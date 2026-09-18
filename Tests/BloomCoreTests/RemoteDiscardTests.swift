import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

@Suite("Cloud workspace discard", .scratchDirectory, .tags(.subprocess))
struct RemoteDiscardTests {
    private func fixture() async throws -> (repo: TempRepo, workspace: Workspace) {
        let repo = try await TempRepo()
        try repo.write("queue.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try await repo.commit("The queue as it was")
        let workspace = Workspace(repoID: .new(), name: "Queue", branch: "main", path: repo.path, baseBranch: "main")
        return (repo, workspace)
    }

    @Test("reverting a file puts it back to what the diff was measured against")
    func revertFile() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        try repo.write("queue.txt", "rewritten\n")
        try repo.write("new.txt", "untracked\n")

        try await RemoteDiscard.revertFile(workspace: workspace, path: "queue.txt", scope: .uncommitted)
        #expect(repo.read("queue.txt")?.hasPrefix("line 1") == true)

        await #expect(throws: RemoteFailure.self) {
            try await RemoteDiscard.revertFile(workspace: workspace, path: "new.txt", scope: .uncommitted)
        }
        #expect(repo.exists("new.txt"), "An untracked file is left alone rather than deleted")
        await #expect(throws: RemoteFailure.self) {
            try await RemoteDiscard.revertFile(workspace: workspace, path: "nothing.txt", scope: .uncommitted)
        }
    }

    @Test("discarding one hunk leaves the rest of the file's changes alone")
    func discardOneHunk() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        var lines = (1...20).map { "line \($0)" }
        lines[0] = "first change"
        lines[19] = "second change"
        try repo.write("queue.txt", lines.joined(separator: "\n") + "\n")

        let patch = try await RemoteReview.patch(workspace: workspace, path: "queue.txt", scope: .uncommitted)
        let hunks = DiffParser.parse(patch).flatMap(\.hunks)
        #expect(hunks.count == 2, "Two edits far enough apart to be two hunks")
        let first = try #require(hunks.first)
        let text = "@@ -\(first.oldStart),\(first.oldCount) +\(first.newStart),\(first.newCount) @@\n"
            + first.lines.map { line in
                switch line.kind {
                case .addition: "+" + line.text
                case .deletion: "-" + line.text
                case .context: " " + line.text
                case .noNewline: "\\" + line.text
                }
            }.joined(separator: "\n") + "\n"

        try await RemoteDiscard.discardHunk(workspace: workspace, path: "queue.txt", scope: .uncommitted, patch: text)
        let after = try #require(repo.read("queue.txt"))
        #expect(after.contains("line 1"), "The discarded hunk is back to the baseline")
        #expect(after.contains("second change"), "The other hunk is untouched")
    }

    @Test("a hunk from a file changed both staged and unstaged is discarded from the diff the client read")
    func discardAcrossLayers() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        var lines = (1...20).map { "line \($0)" }
        lines[0] = "staged change"
        try repo.write("queue.txt", lines.joined(separator: "\n") + "\n")
        try await Shell.check("git", ["add", "queue.txt"], cwd: repo.path)
        lines[19] = "unstaged change"
        try repo.write("queue.txt", lines.joined(separator: "\n") + "\n")

        // What a client reads: one diff against HEAD with both changes in it.
        let patch = try await RemoteReview.patch(workspace: workspace, path: "queue.txt", scope: .uncommitted)
        let hunks = DiffParser.parse(patch).flatMap(\.hunks)
        #expect(hunks.count == 2)
        let last = try #require(hunks.last)
        let text = "@@ -\(last.oldStart),\(last.oldCount) +\(last.newStart),\(last.newCount) @@\n"
            + last.lines.map { line in
                switch line.kind {
                case .addition: "+" + line.text
                case .deletion: "-" + line.text
                case .context: " " + line.text
                case .noNewline: "\\" + line.text
                }
            }.joined(separator: "\n") + "\n"

        try await RemoteDiscard.discardHunk(workspace: workspace, path: "queue.txt", scope: .uncommitted, patch: text)
        let after = try #require(repo.read("queue.txt"))
        #expect(after.contains("line 20"), "The unstaged hunk went")
        #expect(after.contains("staged change"), "The staged one stays")
    }

    @Test("a hunk that no longer matches the file is refused rather than guessed at")
    func staleHunkIsRefused() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        try repo.write("queue.txt", (["changed"] + (2...20).map { "line \($0)" }).joined(separator: "\n") + "\n")
        let stale = "@@ -1,3 +1,3 @@\n-line 1\n+something else entirely\n line 2\n line 3\n"

        await #expect(throws: RemoteFailure.self) {
            try await RemoteDiscard.discardHunk(workspace: workspace, path: "queue.txt", scope: .uncommitted, patch: stale)
        }
        #expect(repo.read("queue.txt")?.hasPrefix("changed") == true, "Nothing was written")

        await #expect(throws: RemoteFailure.self) {
            try await RemoteDiscard.discardHunk(workspace: workspace, path: "queue.txt", scope: .uncommitted, patch: "not a patch")
        }
    }

    @Test("staged and unstaged work is listed with the layer it is in")
    func layersAreReported() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        try repo.write("queue.txt", (["staged change"] + (2...20).map { "line \($0)" }).joined(separator: "\n") + "\n")
        try await Shell.check("git", ["add", "queue.txt"], cwd: repo.path)
        try repo.write("queue.txt", (["staged change"] + (2...19).map { "line \($0)" } + ["unstaged change"]).joined(separator: "\n") + "\n")

        let files = try await Git.changedFiles(worktree: repo.path, base: "HEAD", scope: .uncommitted)
        let records = files.map { $0.record(contentRevision: nil) }
        #expect(Set(records.compactMap(\.layer)) == ["staged", "unstaged"])
        _ = workspace
    }
}

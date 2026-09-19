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

    /// One hunk written back out as a patch, which is what a client holds after reading a file's
    /// diff and the only thing this API accepts as a name for it.
    private func hunkText(_ hunk: DiffHunk) -> String {
        "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n"
            + hunk.lines.map { line in
                switch line.kind {
                case .addition: "+" + line.text
                case .deletion: "-" + line.text
                case .context: " " + line.text
                case .noNewline: "\\" + line.text
                }
            }.joined(separator: "\n") + "\n"
    }

    /// A file staged with one change and edited again in the worktree, which is the only shape in
    /// which the four scopes are four different diffs.
    private func stagedAndEdited(_ repo: TempRepo) async throws {
        var lines = (1...20).map { "line \($0)" }
        lines[0] = "staged change"
        try repo.write("queue.txt", lines.joined(separator: "\n") + "\n")
        try await Shell.check("git", ["add", "queue.txt"], cwd: repo.path)
        lines[19] = "unstaged change"
        try repo.write("queue.txt", lines.joined(separator: "\n") + "\n")
    }

    /// What a commit would take, read out of the index rather than off disk.
    private func indexCopy(_ repo: TempRepo, _ path: String) async throws -> String {
        try await Shell.check("git", ["show", ":" + path], cwd: repo.path).stdout
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
        let text = hunkText(try #require(hunks.first))

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
        let text = hunkText(try #require(hunks.last))

        try await RemoteDiscard.discardHunk(workspace: workspace, path: "queue.txt", scope: .uncommitted, patch: text)
        let after = try #require(repo.read("queue.txt"))
        #expect(after.contains("line 20"), "The unstaged hunk went")
        #expect(after.contains("staged change"), "The staged one stays")
    }

    @Test("the staged and unstaged scopes read the two sides of the index, and carry their layer")
    func stagedAndUnstagedScopes() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        try await stagedAndEdited(repo)
        try repo.write("fresh.txt", "never seen\n")

        let staged = try await RemoteReview.changes(workspace: workspace, scope: .staged)
        #expect(staged.map(\.path) == ["queue.txt"], "What a commit would take, and nothing untracked")
        #expect(staged.first?.layer == .staged)

        let unstaged = try await RemoteReview.changes(workspace: workspace, scope: .unstaged)
        #expect(Set(unstaged.map(\.path)) == ["queue.txt", "fresh.txt"], "What a commit would leave behind")
        #expect(unstaged.first(where: { $0.path == "queue.txt" })?.layer == .unstaged)

        // The patches are the two sides of the index rather than the same diff twice.
        let stagedPatch = try await RemoteReview.patch(workspace: workspace, path: "queue.txt", scope: .staged)
        #expect(stagedPatch.contains("+staged change") && !stagedPatch.contains("+unstaged change"))
        let unstagedPatch = try await RemoteReview.patch(workspace: workspace, path: "queue.txt", scope: .unstaged)
        #expect(unstagedPatch.contains("+unstaged change") && !unstagedPatch.contains("+staged change"))
    }

    @Test("discard in the staged scope unstages, and the worktree keeps every word of it")
    func unstageWholeFile() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        try await stagedAndEdited(repo)

        try await RemoteDiscard.revertFile(workspace: workspace, path: "queue.txt", scope: .staged)

        let onDisk = try #require(repo.read("queue.txt"))
        #expect(onDisk.contains("staged change"), "Unstaging destroys nothing anybody wrote")
        #expect(onDisk.contains("unstaged change"))
        let index = try await indexCopy(repo, "queue.txt")
        #expect(index.contains("line 1"), "The index is back to HEAD")
        let stillStaged = try await RemoteReview.changes(workspace: workspace, scope: .staged)
        #expect(stillStaged.isEmpty)
    }

    @Test("discard in the unstaged scope throws the worktree's copy away and leaves the index")
    func discardWholeFileInTheWorktree() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        try await stagedAndEdited(repo)

        try await RemoteDiscard.revertFile(workspace: workspace, path: "queue.txt", scope: .unstaged)

        let onDisk = try #require(repo.read("queue.txt"))
        #expect(!onDisk.contains("unstaged change"), "The only scope where something is lost")
        #expect(onDisk.contains("staged change"), "The worktree is the index's copy, not HEAD's")
        let index = try await indexCopy(repo, "queue.txt")
        #expect(index.contains("staged change"))
    }

    @Test("a hunk discarded in the staged scope leaves the index and touches no file")
    func unstageOneHunk() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        try await stagedAndEdited(repo)
        // A second staged change, so there is a hunk to keep as well as one to unstage.
        var lines = (1...20).map { "line \($0)" }
        lines[0] = "staged change"
        lines[9] = "second staged change"
        try repo.write("queue.txt", lines.joined(separator: "\n") + "\n")
        try await Shell.check("git", ["add", "queue.txt"], cwd: repo.path)
        lines[19] = "unstaged change"
        try repo.write("queue.txt", lines.joined(separator: "\n") + "\n")

        let patch = try await RemoteReview.patch(workspace: workspace, path: "queue.txt", scope: .staged)
        let hunks = DiffParser.parse(patch).flatMap(\.hunks)
        #expect(hunks.count == 2, "Two staged edits far enough apart to be two hunks")
        let before = try #require(repo.read("queue.txt"))

        try await RemoteDiscard.discardHunk(
            workspace: workspace, path: "queue.txt", scope: .staged, patch: hunkText(try #require(hunks.first))
        )

        #expect(repo.read("queue.txt") == before, "Unstaging a hunk writes nothing to the worktree")
        let index = try await indexCopy(repo, "queue.txt")
        #expect(index.contains("line 1"), "The unstaged hunk left the index")
        #expect(index.contains("second staged change"), "The other staged hunk is still there")
    }

    @Test("a hunk discarded in the unstaged scope is reversed in the worktree and nowhere else")
    func discardOneHunkInTheWorktree() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        try await stagedAndEdited(repo)

        let patch = try await RemoteReview.patch(workspace: workspace, path: "queue.txt", scope: .unstaged)
        let hunks = DiffParser.parse(patch).flatMap(\.hunks)
        #expect(hunks.count == 1, "The index to the worktree is the one edit made since staging")

        try await RemoteDiscard.discardHunk(
            workspace: workspace, path: "queue.txt", scope: .unstaged, patch: hunkText(try #require(hunks.first))
        )

        let onDisk = try #require(repo.read("queue.txt"))
        #expect(!onDisk.contains("unstaged change"), "That is what discard means here")
        #expect(onDisk.contains("staged change"), "The staged hunk is untouched in both places")
        let index = try await indexCopy(repo, "queue.txt")
        #expect(index.contains("staged change"))
    }

    @Test("a file staged and then put back in the worktree is still readable in the staged scope")
    func stagedOnlyFileIsFound() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        let original = try #require(repo.read("queue.txt"))
        try repo.write("queue.txt", (["staged change"] + (2...20).map { "line \($0)" }).joined(separator: "\n") + "\n")
        try await Shell.check("git", ["add", "queue.txt"], cwd: repo.path)
        try repo.write("queue.txt", original)

        // Nothing against HEAD, everything against the index: the one file the whole comparison
        // cannot see, and the reason a scope looks its files up in its own list.
        let wholeComparison = try await RemoteReview.changes(workspace: workspace, scope: .uncommitted)
        #expect(wholeComparison.isEmpty)
        let patch = try await RemoteReview.patch(workspace: workspace, path: "queue.txt", scope: .staged)
        #expect(patch.contains("+staged change"))

        try await RemoteDiscard.revertFile(workspace: workspace, path: "queue.txt", scope: .staged)
        let afterUnstaging = try await RemoteReview.changes(workspace: workspace, scope: .staged)
        #expect(afterUnstaging.isEmpty)
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

    /// Item 8 of the review of 19 September 2026: a revert or a discard names a file the review
    /// lists, so a path outside the worktree is not a file it can find.
    @Test func revertAndDiscardFindNothingOutsideTheWorktree() async throws {
        let (repo, workspace) = try await fixture()
        let outside = TestScratch.unique("outside")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "outside secret".write(toFile: outside + "/value.txt", atomically: true, encoding: .utf8)
        try repo.write("queue.txt", "changed\n")
        for path in ["../queue.txt", outside + "/value.txt", "nested/../../value.txt"] {
            await #expect(throws: RemoteFailure.self, "revert \(path)") {
                try await RemoteDiscard.revertFile(workspace: workspace, path: path, scope: .uncommitted)
            }
            await #expect(throws: RemoteFailure.self, "discard \(path)") {
                try await RemoteDiscard.discardHunk(workspace: workspace, path: path, scope: .uncommitted,
                                                    patch: "@@ -1 +1 @@\n-a\n+b\n")
            }
        }
        #expect(try String(contentsOfFile: outside + "/value.txt", encoding: .utf8) == "outside secret")
    }
}

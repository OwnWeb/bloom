import Foundation
import Testing
@testable import BloomCore

@Suite("Local merge", .tags(.git, .subprocess), ScratchDirectoryTrait())
struct LocalMergeTests {
    @Test("merges a workspace branch into local main without a remote")
    func mergesWithoutRemote() async throws {
        let (repo, worktree) = try await fixture()
        defer { repo.cleanUp() }
        try worktree.write("feature.txt", "done\n")
        try await worktree.commit("Add feature")

        let outcome = try await Git.mergeLocally(branch: "feature", from: worktree.path, into: "main", at: repo.path)
        #expect(outcome == .merged)
        #expect(repo.read("feature.txt") == "done\n")
        #expect(try await Git.currentBranch(of: worktree.path) == "feature")

        let repeated = try await Git.mergeLocally(branch: "feature", from: worktree.path, into: "main", at: repo.path)
        #expect(repeated == .alreadyMerged)
    }

    @Test("refuses a dirty base checkout without changing either branch")
    func refusesDirtyBase() async throws {
        let (repo, worktree) = try await fixture()
        defer { repo.cleanUp() }
        try worktree.write("feature.txt", "done\n")
        try await worktree.commit("Add feature")
        try repo.write("README.md", "local edit\n")
        let originalHead = try await Git.headSHA(of: repo.path)

        await #expect(throws: ShellError.self) {
            try await Git.mergeLocally(branch: "feature", from: worktree.path, into: "main", at: repo.path)
        }
        #expect(try await Git.headSHA(of: repo.path) == originalHead)
        #expect(repo.read("README.md") == "local edit\n")
    }

    @Test("aborts a conflicting merge and leaves main clean")
    func abortsConflict() async throws {
        let (repo, worktree) = try await fixture()
        defer { repo.cleanUp() }
        try worktree.write("README.md", "feature\n")
        try await worktree.commit("Change readme on feature")
        try repo.write("README.md", "main\n")
        try await repo.commit("Change readme on main")
        let originalHead = try await Git.headSHA(of: repo.path)

        await #expect(throws: ShellError.self) {
            try await Git.mergeLocally(branch: "feature", from: worktree.path, into: "main", at: repo.path)
        }
        #expect(try await Git.headSHA(of: repo.path) == originalHead)
        #expect(repo.read("README.md") == "main\n")
        let status = try await Shell.check("git", ["status", "--porcelain"], cwd: repo.path)
        #expect(status.stdout.isEmpty)
    }

    private func fixture() async throws -> (TempRepo, TempRepo) {
        let repo = try await TempRepo()
        let worktreePath = TestScratch.unique("local-merge-worktree")
        try await Shell.check("git", ["worktree", "add", "-q", "-b", "feature", worktreePath, "main"], cwd: repo.path)
        return (repo, TempRepo(existing: worktreePath))
    }
}

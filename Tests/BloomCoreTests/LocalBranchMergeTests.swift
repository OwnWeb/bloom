import Foundation
import Testing
@testable import BloomCore

@Suite("Local branch merge", .tags(.git), .scratchDirectory)
struct LocalBranchMergeTests {
    @Test("merges a clean workspace into local main without touching its checkout")
    func mergesLocally() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let source = TestScratch.unique("local-merge")
        try await Git.addWorktree(repo: repo.path, path: source, branch: "feature", base: "main")
        let workspace = TempRepo(existing: source)
        try workspace.write("feature.txt", "finished\n")
        try await workspace.commit("Feature")

        let before = try await Git.headSHA(of: source)
        let plan = try await LocalBranchMerger.shared.prepare(source: "feature", target: "main", in: source)
        try await LocalBranchMerger.shared.merge(plan)

        #expect(try await Git.currentBranch(of: source) == "feature")
        #expect(try await Git.headSHA(of: source) == before)
        #expect(try await Git.currentBranch(of: repo.path) == "main")
        #expect(try String(contentsOfFile: repo.path + "/feature.txt", encoding: .utf8) == "finished\n")
        let parents = try await Shell.check("git", ["rev-list", "--parents", "-n", "1", "HEAD"], cwd: repo.path)
        #expect(parents.trimmed.split(separator: " ").count == 3)
    }

    @Test("refuses dirty source and target checkouts")
    func refusesDirtyCheckouts() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let source = TestScratch.unique("local-merge")
        try await Git.addWorktree(repo: repo.path, path: source, branch: "feature", base: "main")
        let workspace = TempRepo(existing: source)
        try workspace.write("feature.txt", "finished\n")
        try await workspace.commit("Feature")
        let targetBefore = try await Git.headSHA(of: repo.path)

        try workspace.write("untracked.txt", "keep\n")
        await expectRefusal(source: source, containing: "feature")
        try FileManager.default.removeItem(atPath: source + "/untracked.txt")

        try repo.write("untracked.txt", "keep\n")
        await expectRefusal(source: source, containing: "main")
        #expect(try await Git.headSHA(of: repo.path) == targetBefore)
    }

    @Test("a conflict is aborted and leaves the target clean")
    func abortsConflict() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let source = TestScratch.unique("local-merge")
        try await Git.addWorktree(repo: repo.path, path: source, branch: "feature", base: "main")
        let workspace = TempRepo(existing: source)
        try workspace.write("README.md", "feature\n")
        try await workspace.commit("Feature")
        try repo.write("README.md", "main\n")
        try await repo.commit("Main")
        let targetBefore = try await Git.headSHA(of: repo.path)

        let plan = try await LocalBranchMerger.shared.prepare(source: "feature", target: "main", in: source)
        do {
            try await LocalBranchMerger.shared.merge(plan)
            Issue.record("A conflicting merge succeeded")
        } catch let error as LocalMergeFailure {
            #expect(error.message.contains("aborted"))
        }

        #expect(try await Git.headSHA(of: repo.path) == targetBefore)
        #expect(try String(contentsOfFile: repo.path + "/README.md", encoding: .utf8) == "main\n")
        let status = try await Shell.check("git", ["status", "--porcelain"], cwd: repo.path)
        #expect(status.trimmed.isEmpty)
    }

    private func expectRefusal(source: String, containing text: String) async {
        do {
            _ = try await LocalBranchMerger.shared.prepare(source: "feature", target: "main", in: source)
            Issue.record("Dirty checkout was accepted")
        } catch let error as LocalMergeFailure {
            #expect(error.message.contains(text))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

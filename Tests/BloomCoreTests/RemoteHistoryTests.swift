import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

@Suite("Cloud workspace history", .scratchDirectory, .tags(.subprocess))
struct RemoteHistoryTests {
    /// A repository with two commits on a branch cut from `main`.
    private func fixture() async throws -> (repo: TempRepo, workspace: Workspace) {
        let repo = try await TempRepo()
        try await Shell.check("git", ["checkout", "-q", "-b", "queue-retries"], cwd: repo.path)
        try repo.write("first.txt", "one\n")
        try await repo.commit("Retry the queue")
        try repo.write("second.txt", "two\n")
        try await repo.commit("And wait between tries")
        let workspace = Workspace(repoID: .new(), name: "Queue", branch: "queue-retries", path: repo.path, baseBranch: "main")
        return (repo, workspace)
    }

    @Test("the page holds the branch's own commits, newest first, with what git knows about each")
    func pageIsTheBranchesCommits() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        let page = try await RemoteHistory.page(workspace: workspace, limit: nil, before: nil)

        #expect(page.commits.map(\.subject) == ["And wait between tries", "Retry the queue"])
        #expect(!page.hasMore)
        let newest = try #require(page.commits.first)
        #expect(newest.authorName.isEmpty == false)
        #expect(newest.authorEmail.contains("@"))
        #expect(newest.sha.count == 40)
        #expect(newest.parents.count == 1)
        #expect(newest.pushed == nil, "A branch with no remote is not the same as one that is not pushed")
    }

    @Test("a limit pages, and `before` reads on from the commit it names")
    func pagingWalksBack() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        let first = try await RemoteHistory.page(workspace: workspace, limit: 1, before: nil)
        #expect(first.commits.map(\.subject) == ["And wait between tries"])
        #expect(first.hasMore)

        let next = try await RemoteHistory.page(workspace: workspace, limit: 1, before: try #require(first.commits.first?.sha))
        #expect(next.commits.map(\.subject) == ["Retry the queue"])
        #expect(!next.hasMore)

        await #expect(throws: RemoteFailure.self) {
            try await RemoteHistory.page(workspace: workspace, limit: 1, before: String(repeating: "a", count: 40))
        }
    }

    @Test("a commit's files are read from its own two trees")
    func commitFiles() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        let page = try await RemoteHistory.page(workspace: workspace, limit: nil, before: nil)
        let newest = try #require(page.commits.first)
        let files = try await RemoteHistory.files(workspace: workspace, sha: newest.sha)

        #expect(files.map(\.path) == ["second.txt"], "Only what this commit changed, not the branch")
        #expect(files.first?.change == "added")
        #expect(files.first?.additions == 1)

        await #expect(throws: RemoteFailure.self) { try await RemoteHistory.files(workspace: workspace, sha: "not-a-commit") }
        await #expect(throws: RemoteFailure.self) {
            try await RemoteHistory.files(workspace: workspace, sha: String(repeating: "b", count: 40))
        }
    }

    @Test("commits the remote already has are marked pushed, and the rest are not")
    func pushedIsKnownWhenThereIsARemote() async throws {
        let (repo, workspace) = try await fixture()
        defer { repo.cleanUp() }
        // A bare repository beside it, with only the first commit pushed to the branch.
        let remote = TestScratch.unique("bloom-remote") + ".git"
        try await Shell.check("git", ["init", "-q", "--bare", remote], cwd: repo.path)
        try await Shell.check("git", ["remote", "add", "origin", remote], cwd: repo.path)
        try await Shell.check("git", ["push", "-q", "origin", "HEAD~1:refs/heads/queue-retries"], cwd: repo.path)
        try await Shell.check("git", ["fetch", "-q", "origin"], cwd: repo.path)

        let page = try await RemoteHistory.page(workspace: workspace, limit: nil, before: nil)
        #expect(page.commits.map(\.pushed) == [false, true])
    }
}

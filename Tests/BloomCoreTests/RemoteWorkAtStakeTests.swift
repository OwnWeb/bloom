import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

@Suite("What a Cloud workspace would lose", .scratchDirectory, .tags(.subprocess))
struct RemoteWorkAtStakeTests {
    @Test("counts the work that exists only here, and says so per kind")
    func countsEachKind() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let workspace = Workspace(repoID: .new(), name: "Queue", branch: "main", path: repo.path, baseBranch: "main")

        let clean = try #require(await RemoteWorkAtStake.measure(workspace: workspace))
        #expect(clean.uncommitted == 0 && clean.untracked == 0)
        // A repository with no remote at all: every commit in it exists only here, which is what
        // this is for. Answering zero because there was no ref to compare with is the mistake.
        #expect(clean.unpushedCommits >= 1)

        try repo.write("tracked.txt", "one\n")
        try await repo.commit("Something to change")
        try repo.write("tracked.txt", "two\n")
        try repo.write("new.txt", "never seen\n")
        let dirty = try #require(await RemoteWorkAtStake.measure(workspace: workspace))
        #expect(dirty.uncommitted == 1)
        #expect(dirty.untracked == 1)
        // No remote at all, so every commit on this branch lives only here. The count is measured
        // rather than assumed: a repository built from a template starts with its own commits.
        #expect(dirty.unpushedCommits >= 1)
    }

    @Test("a commit that is pushed is not counted, and one that is not is")
    func pushedCommitsAreNotAtStake() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let remote = TestScratch.unique("bloom-remote") + ".git"
        try await Shell.check("git", ["init", "-q", "--bare", remote], cwd: repo.path)
        try await Shell.check("git", ["remote", "add", "origin", remote], cwd: repo.path)
        try await Shell.check("git", ["push", "-q", "origin", "HEAD:refs/heads/main"], cwd: repo.path)
        try await Shell.check("git", ["fetch", "-q", "origin"], cwd: repo.path)
        let workspace = Workspace(repoID: .new(), name: "Queue", branch: "main", path: repo.path, baseBranch: "main")

        let pushed = try #require(await RemoteWorkAtStake.measure(workspace: workspace))
        #expect(pushed.unpushedCommits == 0, "Everything is on the remote")

        try repo.write("later.txt", "after the push\n")
        try await repo.commit("Only here")
        let ahead = try #require(await RemoteWorkAtStake.measure(workspace: workspace))
        #expect(ahead.unpushedCommits == 1)
        #expect(ahead.uncommitted == 0 && ahead.untracked == 0)
    }

    @Test("a worktree git cannot be asked about answers nothing rather than zero")
    func unknownIsNotZero() async throws {
        let missing = Workspace(repoID: .new(), name: "Gone", branch: "main", path: TestScratch.unique("not-there"), baseBranch: "main")
        #expect(await RemoteWorkAtStake.measure(workspace: missing) == nil)
    }

    @Test("a rename counts once, not twice")
    func renameCountsOnce() {
        // `status -z` writes the entry and then the old path as its own record.
        let entries = RemoteWorkAtStake.entries("R  new.txt\0old.txt\0 M other.txt\0?? fresh.txt\0")
        #expect(entries.count == 3)
        #expect(entries.filter { $0.hasPrefix("??") }.count == 1)
    }

    @Test("the summary leaves the counts out when they are unknown, and sends them when they are known")
    func summaryOmitsUnknownCounts() throws {
        let base = RemoteSummary(
            revision: 1, observedAt: Date(), bloomRunnerVersion: "1.0.0", bloomRunnerCapabilities: [],
            title: "Queue", branch: "queue", baseBranch: "main",
            state: "idle", awake: true, setup: .init(state: "succeeded"), diff: .init(files: 0, additions: 0, deletions: 0),
            chats: [], presentUserIDs: []
        )
        let unknown = String(decoding: try WireJSON.encode(base), as: UTF8.self)
        #expect(!unknown.contains("uncommitted"))
        #expect(!unknown.contains("unpushed_commits"))

        var known = base
        known.uncommitted = 0
        known.untracked = 7
        known.unpushedCommits = 0
        let sent = String(decoding: try WireJSON.encode(known), as: UTF8.self)
        #expect(sent.contains("\"uncommitted\":0"), "A measured zero is sent; only an unknown is left out")
        #expect(sent.contains("\"untracked\":7"))
    }
}

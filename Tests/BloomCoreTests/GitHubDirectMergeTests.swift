import Foundation
import Testing
@testable import BloomCore

@Suite("Direct GitHub merge", .tags(.git), .scratchDirectory)
struct GitHubDirectMergeTests {
    @Test("uses the confirmed PR number, method and head without override flags")
    func mergesTheConfirmedHead() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        let head = try await Git.headSHA(of: repo.path)
        let gh = MergeGH(head: head)

        let outcome = try await GitHub.$commandOverride.withValue({ arguments, _ in
            await gh.execute(arguments)
        }) {
            try await GitHub.mergePullRequest(expected(head: head), into: "main", method: .squash, worktree: repo.path)
        }

        #expect(outcome == .merged)
        #expect(await gh.mergeArguments == [
            "pr", "merge", "42", "--squash", "--match-head-commit", head,
        ])
        #expect(try await Git.headSHA(of: repo.path) == head)
    }

    @Test("a newly pushed head refuses the direct merge")
    func refusesChangedHead() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        let head = try await Git.headSHA(of: repo.path)
        let gh = MergeGH(head: String(repeating: "a", count: 40))

        do {
            _ = try await GitHub.$commandOverride.withValue({ arguments, _ in
                await gh.execute(arguments)
            }) {
                try await GitHub.mergePullRequest(expected(head: head), into: "main", method: .merge, worktree: repo.path)
            }
            Issue.record("A changed PR head was merged")
        } catch let error as GitHubError {
            #expect(error.message.contains("changed"))
        }
        #expect(await gh.mergeArguments == nil)
    }

    @Test("untracked work stops the merge before gh is called")
    func refusesDirtyCheckout() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        let head = try await Git.headSHA(of: repo.path)
        try repo.write("untracked.txt", "keep\n")
        let gh = MergeGH(head: head)

        do {
            _ = try await GitHub.$commandOverride.withValue({ arguments, _ in
                await gh.execute(arguments)
            }) {
                try await GitHub.mergePullRequest(expected(head: head), into: "main", method: .rebase, worktree: repo.path)
            }
            Issue.record("A dirty checkout was merged")
        } catch let error as GitHubError {
            #expect(error.message.contains("changes or commits"))
        }
        #expect(await gh.callCount == 0)
    }

    private func expected(head: String) -> PullRequest {
        PullRequest(
            number: 42, title: "Feature", url: "https://github.com/org/repo/pull/42",
            state: "OPEN", branch: "feature", baseBranch: "main", headRevision: head
        )
    }
}

private actor MergeGH {
    let head: String
    private(set) var callCount = 0
    private(set) var mergeArguments: [String]?
    private var merged = false

    init(head: String) { self.head = head }

    func execute(_ arguments: [String]) -> ShellResult {
        callCount += 1
        if arguments.starts(with: ["pr", "merge"]) {
            mergeArguments = arguments
            merged = true
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        let state = merged ? "MERGED" : "OPEN"
        return ShellResult(status: 0, stdout: """
            {"number":42,"title":"Feature","url":"https://github.com/org/repo/pull/42",\
            "state":"\(state)","isDraft":false,"mergeable":"MERGEABLE",\
            "headRefName":"feature","baseRefName":"main","headRefOid":"\(head)"}
            """, stderr: "")
    }
}

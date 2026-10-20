import Foundation
import Testing
@testable import BloomCore

@Suite("Changing a workspace's base branch")
struct BaseBranchChangeTests {
    @Test("Local and remote branches are offered once, in order, without the workspace's own")
    func options() {
        #expect(
            BaseBranchChange.options(
                local: ["main", "quiet-harbour", "ownweb"],
                remote: ["main", "colleague/idea", ""],
                excluding: "quiet-harbour"
            ) == ["colleague/idea", "main", "ownweb"]
        )
    }

    @Test("The workspace's own branch is refused, even when the listing has it")
    func ownBranchRefused() {
        let refusal = BaseBranchChange.refusal(
            of: "quiet-harbour", branch: "quiet-harbour", available: ["main", "quiet-harbour"]
        )
        #expect(refusal?.contains("own branch") == true)
    }

    @Test("A branch the listing does not have is refused")
    func missingBranchRefused() {
        let refusal = BaseBranchChange.refusal(
            of: "deleted-meanwhile", branch: "quiet-harbour", available: ["main", "ownweb"]
        )
        #expect(refusal?.contains("not a branch") == true)
    }

    @Test("A workspace with no worktree on this Mac lists nothing rather than asking elsewhere")
    func noWorktreeListsNothing() async {
        #expect(await BaseBranchChange.load(repoPath: "", excluding: "quiet-harbour").isEmpty)
    }

    @Test("A listed branch is accepted")
    func listedBranchAccepted() {
        #expect(
            BaseBranchChange.refusal(of: "ownweb", branch: "quiet-harbour", available: ["main", "ownweb"])
                == nil
        )
    }
}

@Suite("Listing a workspace's possible bases", .tags(.git, .destructive), .scratchDirectory)
struct BaseBranchChangeListingTests {
    @Test("A worktree lists the repository's branches, less its own")
    func listsFromWorktree() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("base-branch-change")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Fix draft tickets")
        try await Shell.check("git", ["branch", "ownweb"], cwd: repo.path)

        let options = await BaseBranchChange.load(repoPath: workspace.path, excluding: workspace.branch)

        #expect(options.contains("main"))
        #expect(options.contains("ownweb"))
        #expect(!options.contains(workspace.branch))
    }

    @Test("A new base is written where git and gh read it, not only in the store")
    func recordsInGit() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("base-branch-record")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Fix draft tickets")
        try await Shell.check("git", ["branch", "ownweb"], cwd: repo.path)

        try await BaseBranchChange.record("ownweb", for: workspace)

        let recorded = try await Shell.run(
            "git", ["config", "branch.\(workspace.branch).gh-merge-base"], cwd: workspace.path
        )
        #expect(recorded.trimmed == "ownweb")
        #expect(try await Git.repositoryContext(in: workspace.path).baseBranch == "ownweb")
    }
}

import Foundation
import Testing
@testable import BloomCore

@Suite("Direct GitLab create and merge", .tags(.git), .scratchDirectory)
struct GitLabDirectTests {
    private let project = "https://gitlab.com/group/app"

    @Test("merges the confirmed head with no auto-merge, the method's flag and the project named")
    func mergesTheConfirmedHead() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)

        for method in [GitHub.MergeMethod.squash, .merge] {
            let glab = MergeGlab(head: head)
            let outcome = try await GitLab.$commandOverride.withValue({ arguments, _ in
                await glab.execute(arguments)
            }) {
                try await GitLab.mergePullRequest(expected(head: head), into: "main", method: method, worktree: repo.path)
            }
            let flags: [String] = method == .squash ? ["--squash"] : []
            let merge = ["mr", "merge", "42", "--yes", "--auto-merge=false", "--sha", head] + flags + ["-R", project]
            #expect(outcome == .merged)
            #expect(await glab.merges == [merge])
        }
    }

    @Test("a rebase runs first, and the rebased head is what gets merged")
    func rebasesThenMerges() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let rebased = String(repeating: "b", count: 40)
        let glab = MergeGlab(head: head, rebasedHead: rebased)

        let outcome = try await GitLab.$commandOverride.withValue({ arguments, _ in
            await glab.execute(arguments)
        }) {
            try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .rebase, worktree: repo.path)
        }

        #expect(outcome == .merged)
        #expect(await glab.rebases == 1)
        #expect(await glab.merges == [
            ["mr", "merge", "42", "--yes", "--auto-merge=false", "--sha", rebased, "-R", project],
        ])
    }

    @Test("a rebase that brought in a commit nobody confirmed is not merged")
    func refusesAnUnconfirmedCommit() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let glab = MergeGlab(head: head, rebasedHead: String(repeating: "b", count: 40), extraAfterRebase: "Sneaked in")

        do {
            _ = try await GitLab.$commandOverride.withValue({ arguments, _ in
                await glab.execute(arguments)
            }) {
                try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .rebase, worktree: repo.path)
            }
            Issue.record("A rebase with an unconfirmed commit was merged")
        } catch let error as GitHubError {
            #expect(error.message.contains("not the ones confirmed"))
        }
        #expect(await glab.merges.isEmpty)
    }

    @Test("a newly pushed head refuses the direct merge before glab merges")
    func refusesChangedHead() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let glab = MergeGlab(head: String(repeating: "a", count: 40))

        do {
            _ = try await GitLab.$commandOverride.withValue({ arguments, _ in
                await glab.execute(arguments)
            }) {
                try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .merge, worktree: repo.path)
            }
            Issue.record("A changed merge request head was merged")
        } catch let error as GitHubError {
            #expect(error.message == "The merge request changed since it was shown. Refresh it before merging.")
        }
        #expect(await glab.merges.isEmpty)
    }

    @Test("opens the merge request from the pushed branch, described by its commits as gh --fill does")
    func createsFromCommits() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        try repo.write("b.txt", "b\n")
        try await Shell.check("git", ["add", "b.txt"], cwd: repo.path)
        try await Shell.check("git", ["commit", "-q", "-m", "Add b"], cwd: repo.path)
        let head = try await Git.headSHA(of: repo.path)
        let glab = MergeGlab(head: head)

        let created = try await GitLab.$commandOverride.withValue({ arguments, _ in
            await glab.execute(arguments)
        }) {
            try await GitLab.createPullRequestFromCommits(worktree: repo.path, base: "main", title: "Feature")
        }

        #expect(created.number == 42)
        #expect(created.forge == .gitLab)
        #expect(await glab.creates == [[
            "mr", "create", "--source-branch", "feature", "--target-branch", "main",
            "--title", "Feature", "--description", "- Add a\n- Add b", "--yes", "-R", project,
        ]])
    }

    @Test("a single commit's body is the description, and glab's printed URL names the request")
    func descriptionAndNumber() {
        #expect(GitLab.description(fromCommits: [(subject: "Add a", body: "Why a\n")]) == "Why a")
        #expect(GitLab.description(fromCommits: []) == "")
        #expect(GitLab.commits(fromLog: "Add a\u{1f}Why\n\u{1e}\nAdd b\u{1f}\u{1e}\n").map { $0.subject } == ["Add a", "Add b"])
        #expect(GitLab.mergeRequestNumber(in: "Creating…\nhttps://gitlab.com/g/app/-/merge_requests/42\n") == 42)
        #expect(GitLab.mergeRequestNumber(in: "nothing here") == nil)
    }

    @Test("GitHub's words for the direct routes are the ones it had")
    func gitHubWords() {
        #expect(Forge.gitHub.command("merge") == "gh pr merge")
        #expect(Forge.gitHub.titledRequest == "Pull request")
        #expect(Forge.gitHub.shortRequest == "PR")
        #expect(Forge.gitLab.command("merge") == "glab mr merge")
        #expect(MergeExecution.direct.label(on: .gitLab) == "Merge with GitLab CLI")
    }

    /// On `feature`, one commit ahead of `main`, with `origin/main` where `main` is.
    private func featureRepo() async throws -> TempRepo {
        let repo = try await TempRepo()
        try await Shell.check("git", ["remote", "add", "origin", "git@gitlab.com:group/app.git"], cwd: repo.path)
        try await Shell.check("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cwd: repo.path)
        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        try repo.write("a.txt", "a\n")
        try await Shell.check("git", ["add", "a.txt"], cwd: repo.path)
        try await Shell.check("git", ["commit", "-q", "-m", "Add a", "-m", "Why a"], cwd: repo.path)
        return repo
    }

    private func expected(head: String) -> PullRequest {
        PullRequest(
            number: 42, title: "Feature", url: "\(project)/-/merge_requests/42", state: "OPEN",
            branch: "feature", baseBranch: "main", headRevision: head, forge: .gitLab
        )
    }
}

/// glab for one merge request, !42 on `feature`, answering the API reads and the mr commands.
private actor MergeGlab {
    private var head: String
    private let rebasedHead: String?
    private let extraAfterRebase: String?
    private var merged = false
    private(set) var merges: [[String]] = []
    private(set) var creates: [[String]] = []
    private(set) var rebases = 0

    init(head: String, rebasedHead: String? = nil, extraAfterRebase: String? = nil) {
        self.head = head
        self.rebasedHead = rebasedHead
        self.extraAfterRebase = extraAfterRebase
    }

    func execute(_ arguments: [String]) -> ShellResult {
        if arguments.starts(with: ["mr", "merge"]) {
            merges.append(arguments)
            merged = true
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        if arguments.starts(with: ["mr", "create"]) {
            creates.append(arguments)
            return ShellResult(status: 0, stdout: "https://gitlab.com/group/app/-/merge_requests/42\n", stderr: "")
        }
        if arguments.starts(with: ["mr", "rebase"]) {
            rebases += 1
            head = rebasedHead ?? head
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        if arguments.last?.hasSuffix("/commits?per_page=100") == true {
            let extra = rebases > 0 ? extraAfterRebase.map { [(String(repeating: "c", count: 40), $0)] } ?? [] : []
            let commits = extra + [(head, "Add a")]
            let listed = commits.map { #"{"id":"\#($0.0)","title":"\#($0.1)"}"# }.joined(separator: ",")
            return ShellResult(status: 0, stdout: "[\(listed)]", stderr: "")
        }
        let state = merged ? "merged" : "opened"
        return ShellResult(status: 0, stdout: """
            {"iid":42,"title":"Feature","web_url":"https://gitlab.com/group/app/-/merge_requests/42",\
            "state":"\(state)","draft":false,"has_conflicts":false,"detailed_merge_status":"mergeable",\
            "source_branch":"feature","target_branch":"main","sha":"\(head)",\
            "source_project_id":1,"target_project_id":1}
            """, stderr: "")
    }
}

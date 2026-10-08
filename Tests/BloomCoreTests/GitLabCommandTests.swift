import Foundation
import Testing
@testable import BloomCore

@Suite("GitLab commands", .tags(.git), .scratchDirectory)
struct GitLabCommandTests {
    @Test("a branch's merge request is found by source branch, then read with its pipeline's jobs")
    func readsByBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["remote", "add", "origin", "git@gitlab.com:group/sub/app.git"], cwd: repo.path)
        let detail = try fixture("mr-not-approved.json")
        let jobs = try fixture("jobs-failed-pipeline.json")
        let log = GlabLog()

        let found = try await GitLab.$commandOverride.withValue({ arguments, _ in
            await log.append(arguments)
            let endpoint = arguments.last ?? ""
            if endpoint.contains("/jobs") { return ShellResult(status: 0, stdout: jobs, stderr: "") }
            if endpoint.contains("source_branch=") { return ShellResult(status: 0, stdout: "[\(detail)]", stderr: "") }
            return ShellResult(status: 0, stdout: detail, stderr: "")
        }) {
            try await GitLab.pullRequest(forBranch: "feature/x", worktree: repo.path)
        }

        #expect(found?.number == 4021)
        #expect(found?.checks == .failing)
        #expect(await log.commands == [
            ["api", "--hostname", "gitlab.com",
             "projects/group%2Fsub%2Fapp/merge_requests?source_branch=feature%2Fx&state=all&order_by=created_at&sort=desc&per_page=20"],
            ["api", "--hostname", "gitlab.com", "projects/group%2Fsub%2Fapp/merge_requests/4021"],
            ["api", "--hostname", "gitlab.com", "projects/34675721/pipelines/2923303483/jobs?per_page=100"],
        ])
    }

    @Test("a fork's merge request on the same branch name is not this branch's")
    func forkIsNotOurs() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["remote", "add", "origin", "git@gitlab.com:gitlab-org/cli.git"], cwd: repo.path)
        let fork = try fixture("mr-draft-conflicting-fork.json")
        let log = GlabLog()

        let found = try await GitLab.$commandOverride.withValue({ arguments, _ in
            await log.append(arguments)
            return ShellResult(status: 0, stdout: "[\(fork)]", stderr: "")
        }) {
            try await GitLab.pullRequest(forBranch: "8591-iteration-list-total", worktree: repo.path)
        }
        #expect(found == nil)
        #expect(await log.commands.count == 1)
    }

    @Test("a pipeline whose jobs cannot be read leaves the checks unknown, not the merge request")
    func unreadableJobs() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["remote", "add", "origin", "git@gitlab.com:gitlab-org/cli.git"], cwd: repo.path)
        let detail = try fixture("mr-not-approved.json")

        let found = try await GitLab.$commandOverride.withValue({ arguments, _ in
            let endpoint = arguments.last ?? ""
            if endpoint.contains("/jobs") { return ShellResult(status: 1, stdout: "", stderr: "403 Forbidden") }
            if endpoint.contains("source_branch=") { return ShellResult(status: 0, stdout: "[\(detail)]", stderr: "") }
            return ShellResult(status: 0, stdout: detail, stderr: "")
        }) {
            try await GitLab.pullRequest(forBranch: "feature", worktree: repo.path)
        }
        #expect(found?.number == 4021)
        #expect(found?.checks == .unavailable)
    }

    @Test("marking ready and checking out name the project rather than letting glab guess")
    func actionsNameTheProject() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["remote", "add", "origin", "https://gitlab.example.com/group/app.git"], cwd: repo.path)
        let draft = PullRequest(number: 7, title: "", url: "", state: "OPEN", isDraft: true, forge: .gitLab)
        let log = GlabLog()

        try await GitLab.$commandOverride.withValue({ arguments, _ in
            await log.append(arguments)
            return ShellResult(status: 0, stdout: "", stderr: "")
        }) {
            try await GitLab.markReadyForReview(draft, worktree: repo.path)
            try await GitLab.checkoutPullRequest(number: 7, into: repo.path, localBranch: "review/7")
        }

        #expect(await log.commands == [
            ["mr", "update", "7", "--ready", "-R", "https://gitlab.example.com/group/app"],
            ["mr", "checkout", "7", "--branch", "review/7", "-R", "https://gitlab.example.com/group/app"],
        ])
    }

    private func fixture(_ name: String) throws -> String {
        let url = try #require(bloomFixtureURL("gitlab/\(name)"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private actor GlabLog {
    private(set) var commands: [[String]] = []

    func append(_ arguments: [String]) {
        commands.append(arguments)
    }
}

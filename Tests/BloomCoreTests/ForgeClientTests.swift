import Foundation
import Testing
@testable import BloomCore

@Suite("Forge client", .scratchDirectory)
struct ForgeClientTests {
    @Test("every repository is asked through GitHub")
    func resolvesGitHub() async {
        let client = await ForgeResolver.client(for: TestScratch.unique("forge"))
        #expect(ObjectIdentifier(client) == ObjectIdentifier(GitHubForge.self))
    }

    @Test("the GitHub client runs the gh command GitHub runs")
    func forwards() async throws {
        let worktree = TestScratch.unique("forge-forward")
        let asked = ArgumentLog()
        let client = await ForgeResolver.client(for: worktree)
        _ = try await GitHub.$commandOverride.withValue({ arguments, _ in
            await asked.record(arguments)
            return ShellResult(status: 0, stdout: #"{"number":1,"headRefName":"feature"}"#, stderr: "")
        }) {
            try await client.pullRequest(forBranch: "feature", worktree: worktree)
        }
        #expect(await asked.first.map { Array($0.prefix(3)) } == ["pr", "view", "feature"])
    }
}

private actor ArgumentLog {
    private(set) var first: [String]?

    func record(_ arguments: [String]) {
        if first == nil { first = arguments }
    }
}

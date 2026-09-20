import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

@Suite("The project's quick prompts on the wire", .scratchDirectory)
struct RemoteQuickPromptsTests {
    private func repo(_ files: [String: String]) throws -> String {
        let root = TestScratch.unique("remote-quick-prompts")
        for (path, contents) in files {
            let full = (root as NSString).appendingPathComponent(path)
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func answer(_ root: String) throws -> (prompts: [QuickPromptRecord], issues: [SettingsIssueRecord]) {
        guard case .quickPrompts(let prompts, let issues) = RemoteQuickPrompts.answer(repo: root) else {
            throw RemoteFailure(.internal, "quick_prompts answered with another kind")
        }
        return (prompts, issues)
    }

    @Test("the file's prompts arrive as the Mac reads them, with paths a client can show")
    func readsTheProjectFile() throws {
        let root = try repo([".bloom/settings.toml": """
            [[quick_prompts]]
            name = "  Explain changes "
            prompt = "Explain what changed on this branch."
            symbol = "doc.text"

            [[quick_prompts]]
            name = "Release notes"
            prompt = "Draft release notes."
            new_chat = true
            """])
        let read = try answer(root)

        #expect(read.prompts.map(\.name) == ["Explain changes", "Release notes"])
        #expect(read.prompts.map(\.id) == ["explain changes", "release notes"])
        #expect(read.prompts.map(\.isNewChat) == [false, true])
        #expect(read.prompts.first?.symbol == "doc.text")
        #expect(read.prompts.allSatisfy { $0.source == ".bloom/settings.toml" },
                "the machine's absolute path means nothing on the other side of the network")
        #expect(read.issues.isEmpty)
    }

    /// **It never sends on its own**, and the person is told why rather than finding the prompt
    /// quietly behaving differently from the file.
    @Test("send_immediately is refused with a sentence, and the prompt is still offered")
    func sendImmediatelyIsRefused() throws {
        let root = try repo([".bloom/settings.toml": """
            [[quick_prompts]]
            name = "Deploy"
            prompt = "Deploy to staging."
            send_immediately = true

            [[quick_prompts]]
            prompt = "No name here."
            """])
        let read = try answer(root)

        #expect(read.prompts.map(\.name) == ["Deploy"])
        #expect(read.issues.count == 2)
        #expect(read.issues.contains { $0.message.contains("send_immediately") })
        #expect(read.issues.contains { $0.message.contains("has no name") })
        #expect(read.issues.allSatisfy { $0.source == ".bloom/settings.toml" && $0.line != nil })
    }

    /// **A symbol outside Bloom's list arrives as the default**, so a client is never handed a name
    /// it has to guess about, and the person is told which one was swapped.
    @Test("a symbol Bloom does not offer arrives as the default, with a sentence")
    func unknownSymbolIsTheDefault() throws {
        let root = try repo([".bloom/settings.toml": """
            [[quick_prompts]]
            name = "Search"
            prompt = "Find where this is used."
            symbol = "text.magnifyingglass"
            """])
        let read = try answer(root)

        #expect(read.prompts.map(\.symbol) == [QuickPrompt.defaultSymbol])
        #expect(read.issues.map(\.message).contains { $0.contains("text.magnifyingglass") })
    }

    /// A menu that explained run scripts would be explaining something it does not show.
    @Test("only issues about quick prompts are reported, and a file that will not parse is one")
    func issuesAreNarrowed() throws {
        let root = try repo([
            ".bloom/settings.toml": """
                [scripts]
                run = 42

                [[quick_prompts]]
                name = "Tests"
                prompt = "Run the tests."
                """,
            ".bloom/settings.local.toml": "this is = = not toml",
        ])
        let read = try answer(root)

        #expect(read.prompts.map(\.name) == ["Tests"])
        #expect(!read.issues.contains { $0.message.hasPrefix("Run scripts") })
        #expect(read.issues.map(\.source) == [".bloom/settings.local.toml"],
                "a file skipped whole took whatever prompts it had with it, so that is worth saying")
    }

    @Test("a path outside the worktree is left as it is rather than cut wrongly")
    func relativePaths() {
        #expect(RemoteQuickPrompts.relative("/w/.bloom/settings.toml", to: "/w") == ".bloom/settings.toml")
        #expect(RemoteQuickPrompts.relative("/w/.bloom/settings.toml", to: "/w/") == ".bloom/settings.toml")
        #expect(RemoteQuickPrompts.relative("/work/.bloom/settings.toml", to: "/w") == "/work/.bloom/settings.toml")
    }
}

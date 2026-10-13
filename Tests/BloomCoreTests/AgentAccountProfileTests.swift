import Foundation
import Testing
@testable import BloomCore

@Suite("Agent account profiles", .tags(.persistence), .scratchDirectory)
struct AgentAccountProfileTests {
    @Test("A session keeps its first account when its project default changes")
    func sessionBinding() async throws {
        let store = try makeTestStore("agent-accounts")
        let repo = try await store.upsert(Repo(name: "client", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "work", branch: "work", path: TestScratch.unique("work"),
            baseBranch: "main"
        ))
        var session = Session(workspaceID: workspace.id, title: "Chat")
        session.agentKind = .codex
        session = try await store.upsert(session)

        let first = try await store.createAgentAccountProfile(kind: .codex, name: "Client A")
        let second = try await store.createAgentAccountProfile(kind: .codex, name: "Client B")
        try await store.setDefaultAccount(first.id, for: repo.id, kind: .codex)
        let launched = try await store.accountForLaunch(session: session)
        try await store.setDefaultAccount(second.id, for: repo.id, kind: .codex)
        let resumed = try await store.accountForLaunch(session: session)

        #expect(launched?.id == first.id)
        #expect(resumed?.id == first.id)
        #expect(try await store.agentAccountProfiles().count == 2)
    }

    @Test("Profiles isolate their home and inherited API key")
    func environment() {
        let environment = AgentAccountEnvironment.applying(
            kind: .codex, home: "/tmp/client", to: ["OPENAI_API_KEY": "old", "PATH": "/bin"]
        )
        #expect(environment["CODEX_HOME"] == "/tmp/client")
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["PATH"] == "/bin")
        #expect(AgentAccountEnvironment.shellArguments(kind: .codex, home: "/tmp/client")
            .contains("CODEX_HOME=/tmp/client"))
        #expect(AgentAccountEnvironment.applying(
            kind: .claudeCode, home: "/tmp/claude", to: ["CLAUDE_CODE_OAUTH_TOKEN": "old"]
        )["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(AgentAccountEnvironment.shellArguments(kind: .grok, home: "/tmp/grok")
            .contains("GROK_HOME=/tmp/grok"))
    }

    @Test("A local project default selects its provider and model")
    func projectModel() async throws {
        let store = try makeTestStore("agent-project-default")
        let repoID = RepoID.new()
        try await store.setProjectAgentDefaults(
            for: repoID, model: "gpt-6.1-sol", effort: "medium", kind: .codex
        )
        var shared = RepoSettings()
        shared.defaultModel = "opus"
        let project = try await store.applyingProjectAgentDefaults(to: shared, for: repoID)
        let resolved = ComposerDefaults.resolve(repo: project, app: AppDefaults())

        #expect(resolved.backend == .codex)
        #expect(resolved.model == "gpt-6.1-sol")
        #expect(resolved.effort == "medium")
    }

    @Test("Removing an unused profile clears project choices and local files")
    func removesUnusedProfile() async throws {
        let store = try makeTestStore("remove-agent-account")
        let profile = try await store.createAgentAccountProfile(kind: .claudeCode, name: "Old client")
        let home = store.agentAccountHome(profile)
        let repoID = RepoID.new()
        try await store.setDefaultAccount(profile.id, for: repoID, kind: .claudeCode)

        try await store.removeAgentAccountProfile(id: profile.id)

        #expect(try await store.agentAccountProfiles().isEmpty)
        #expect(try await store.defaultAccount(for: repoID, kind: .claudeCode) == nil)
        #expect(!FileManager.default.fileExists(atPath: home))
    }

    @Test("A profile used by a saved conversation cannot be removed")
    func refusesBoundProfile() async throws {
        let store = try makeTestStore("bound-agent-account")
        let repo = try await store.upsert(Repo(name: "client", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "work", branch: "work", path: TestScratch.unique("work"),
            baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let profile = try await store.createAgentAccountProfile(kind: .claudeCode, name: "Client")
        try await store.setDefaultAccount(profile.id, for: repo.id, kind: .claudeCode)
        _ = try await store.accountForLaunch(session: session)

        do {
            try await store.removeAgentAccountProfile(id: profile.id)
            Issue.record("A bound profile was removed")
        } catch AgentAccountProfileError.inUse(let count) {
            #expect(count == 1)
        }
        #expect(try await store.agentAccountProfiles().contains(profile))
    }
}

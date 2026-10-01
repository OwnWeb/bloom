import Testing
@testable import BloomCore

@Suite("Local merge mode choice")
struct LocalMergeModeChoiceTests {
    @Test("an unset or unreadable preference uses the agent route")
    func fallback() {
        #expect(LocalMergeModeChoice.resolve(nil) == .agent)
        #expect(LocalMergeModeChoice.resolve("unknown") == .agent)
        #expect(LocalMergeModeChoice.resolve("direct") == .direct)
    }

    @Test("the selected mode survives and is scoped to one project", .tags(.persistence), .scratchDirectory)
    func persistedPerProject() async throws {
        let store = try makeTestStore("local-merge-mode")
        let mine = try await store.upsert(Repo(name: "mine", path: TestScratch.unique("mine")))
        let other = try await store.upsert(Repo(name: "other", path: TestScratch.unique("other")))

        await LocalMergeModeChoice.save(.direct, repoID: mine.id, to: store)

        #expect(await LocalMergeModeChoice.load(repoID: mine.id, from: store) == .direct)
        #expect(await LocalMergeModeChoice.load(repoID: other.id, from: store) == .agent)
        #expect(LocalMergeModeChoice.key(repoID: mine.id) != LocalMergeModeChoice.key(repoID: other.id))
    }
}

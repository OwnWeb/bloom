import Testing
@testable import BloomCore

@Suite("Merge execution choice")
struct MergeExecutionChoiceTests {
    @Test("the direct path is the default for a confirmed PR merge")
    func fallback() {
        #expect(MergeExecutionChoice.resolve(nil) == .direct)
        #expect(MergeExecutionChoice.resolve("unknown") == .direct)
        #expect(MergeExecutionChoice.resolve("agent") == .agent)
    }

    @Test("the selection survives and is scoped to its project", .tags(.persistence), .scratchDirectory)
    func perProject() async throws {
        let store = try makeTestStore("merge-execution")
        let first = try await store.upsert(Repo(name: "first", path: TestScratch.unique("first")))
        let second = try await store.upsert(Repo(name: "second", path: TestScratch.unique("second")))

        await MergeExecutionChoice.save(.agent, repoID: first.id, to: store)

        #expect(await MergeExecutionChoice.load(repoID: first.id, from: store) == .agent)
        #expect(await MergeExecutionChoice.load(repoID: second.id, from: store) == .direct)
    }
}

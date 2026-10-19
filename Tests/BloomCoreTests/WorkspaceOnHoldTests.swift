import Testing
import Foundation
@testable import BloomCore

/// A workspace on hold comes back on its own once anybody sends it a message, because the next
/// move has come back to it.
@Suite("Workspace on hold", .tags(.persistence), .scratchDirectory)
struct WorkspaceOnHoldTests {
    private func seed(_ store: Store, name: String) async throws -> (Workspace, Session) {
        let repo = try await store.upsert(Repo(name: name, path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: "feature/\(name)",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        try await store.update(workspaceID: workspace.id) { $0.onHold = true }
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        return (workspace, session)
    }

    @Test("the mark is stored")
    func theMarkIsStored() async throws {
        let store = try makeTestStore("on-hold")
        let (workspace, _) = try await seed(store, name: "held")

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.onHold)
    }

    @Test("a message takes its own workspace off hold and no other")
    func aMessageTakesItsWorkspaceOffHold() async throws {
        let store = try makeTestStore("on-hold")
        let (spoken, session) = try await seed(store, name: "spoken")
        let (other, _) = try await seed(store, name: "other")

        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "carry on"))

        #expect(try await store.workspace(id: spoken.id)?.onHold == false)
        #expect(try await store.workspace(id: other.id)?.onHold == true)
    }
}

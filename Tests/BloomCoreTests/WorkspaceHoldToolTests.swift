import Foundation
import Testing
@testable import BloomCore

/// `workspace_hold`: an agent sets its own workspace aside once its turn ends, or puts any other
/// on hold or back at once, and nothing that is still going is folded away.
@Suite("Workspace hold tool", .tags(.persistence), .scratchDirectory)
struct WorkspaceHoldToolTests {
    @Test("offered to the owner and to a workspace agent, and self-approved")
    func permissions() {
        let toolbox = BridgeToolbox(handlers: [WorkspaceHoldTool { _, _ in }])
        #expect(toolbox.handler(named: "workspace_hold", for: .owner) != nil)
        #expect(toolbox.handler(named: "workspace_hold", for: .workspace) != nil)
        #expect(BridgeToolApproval.selfApproved.contains("workspace_hold"))
    }

    /// Held mid turn, a permission question asked afterwards would wait unseen under a folded
    /// section, so the agent's own workspace is only booked.
    @Test("an agent's own workspace is booked for the end of its turn, not held now")
    func ownIsBooked() async throws {
        let (store, mine) = try await fixture()
        let session = try await store.upsert(Session(workspaceID: mine.id, title: "Chat"))
        let bookings = Bookings()
        let tool = WorkspaceHoldTool { await bookings.record($0, $1) }

        let result = await tool.call(request([:]), as: agent(in: mine, session: session), store: store)

        #expect(!result.isError, "\(result.text)")
        #expect(await bookings.entries == [Bookings.Entry(workspace: mine.id, session: session.id)])
        #expect(try await store.workspace(id: mine.id)?.onHold == false)
    }

    @Test("an agent's own workspace with a crew member still running is refused")
    func ownWithCrewRunning() async throws {
        let (store, mine) = try await fixture()
        let session = try await store.upsert(Session(workspaceID: mine.id, title: "Chat"))
        var crew = Session(workspaceID: mine.id, title: "Crew")
        crew.state = .running
        try await store.upsert(crew)
        let bookings = Bookings()
        let tool = WorkspaceHoldTool { await bookings.record($0, $1) }

        let result = await tool.call(request([:]), as: agent(in: mine, session: session), store: store)

        #expect(result.isError)
        #expect(await bookings.entries.isEmpty)
    }

    @Test("another workspace named out loud is held at once, and brought back by on_hold false")
    func otherAtOnce() async throws {
        let (store, mine) = try await fixture()
        let theirs = try await second(in: store)
        let bookings = Bookings()
        let tool = WorkspaceHoldTool { await bookings.record($0, $1) }
        let caller = agent(in: mine, session: try await store.upsert(Session(workspaceID: mine.id)))

        let held = await tool.call(request(["workspace": .string(theirs.name)]), as: caller, store: store)
        #expect(!held.isError, "\(held.text)")
        #expect(try await store.workspace(id: theirs.id)?.onHold == true)

        let back = await tool.call(
            request(["workspace": .string(theirs.id.rawValue), "on_hold": .bool(false)]), as: caller, store: store
        )
        #expect(!back.isError, "\(back.text)")
        #expect(try await store.workspace(id: theirs.id)?.onHold == false)
        // Taking one off hold withdraws any booking it had.
        #expect(await bookings.entries == [Bookings.Entry(workspace: theirs.id, session: nil)])
    }

    @Test("a workspace with an agent running there is not put on hold")
    func otherRunning() async throws {
        let (store, _) = try await fixture()
        let theirs = try await second(in: store)
        var busy = Session(workspaceID: theirs.id, title: "Still going")
        busy.state = .running
        try await store.upsert(busy)
        let tool = WorkspaceHoldTool { _, _ in }

        let result = await tool.call(request(["workspace": .string(theirs.name)]), as: .owner, store: store)

        #expect(result.isError)
        #expect(try await store.workspace(id: theirs.id)?.onHold == false)
    }

    @Test("the owner's client must name a workspace, and on_hold must be a boolean")
    func badArguments() async throws {
        let (store, mine) = try await fixture()
        let tool = WorkspaceHoldTool { _, _ in }

        let unnamed = await tool.call(request([:]), as: .owner, store: store)
        let notABool = await tool.call(
            request(["workspace": .string(mine.name), "on_hold": .string("yes")]), as: .owner, store: store
        )

        #expect(unnamed.isError)
        #expect(notABool.isError)
        #expect(try await store.workspace(id: mine.id)?.onHold == false)
    }

    // MARK: - Fixtures

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .integer(1), method: "workspace_hold", params: .object(arguments))
    }

    private func agent(in workspace: Workspace, session: Session) -> BridgeIdentity {
        BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .workspace)
    }

    private func fixture() async throws -> (Store, Workspace) {
        let store = try makeTestStore("hold-tool")
        let repo = try await store.upsert(Repo(name: "Hold tool", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Asked for review", branch: "review",
            path: TestScratch.unique("review"), baseBranch: "main"
        ))
        return (store, workspace)
    }

    private func second(in store: Store) async throws -> Workspace {
        let repo = try await store.upsert(Repo(name: "Other project", path: TestScratch.unique("other")))
        return try await store.upsert(Workspace(
            repoID: repo.id, name: "Somebody else's work", branch: "theirs",
            path: TestScratch.unique("theirs"), baseBranch: "main"
        ))
    }
}

private actor Bookings {
    struct Entry: Equatable {
        var workspace: WorkspaceID
        var session: SessionID?
    }

    var entries: [Entry] = []
    func record(_ workspace: WorkspaceID, _ session: SessionID?) {
        entries.append(Entry(workspace: workspace, session: session))
    }
}

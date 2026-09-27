import Foundation
import Testing
@testable import BloomCore

/// `workspace_rename`: the one thing about a workspace an agent could not correct.
///
/// The suite is store only, exactly as the tool is. It writes through `Store.update(workspaceID:)`
/// and reaches nothing else, which is the statement that this needed no seam into the window: the
/// sidebar hears about a name the same way it hears about one typed into the row.
@Suite("workspace_rename", .tags(.persistence), .scratchDirectory)
struct WorkspaceRenameToolTests {
    private func request(_ arguments: [String: JSONValue] = [:]) -> MCPRequest {
        MCPRequest(id: .number(1), method: "workspace_rename", params: .object(arguments))
    }

    private func answer(_ result: BridgeToolResult) throws -> JSONValue {
        try #require(JSONValue.parse(result.text))
    }

    private func seed(_ store: Store, named name: String = "test") async throws -> Workspace {
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        return try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: "bloom/redesign",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
    }

    private func agent(_ workspace: Workspace) -> BridgeIdentity {
        BridgeIdentity(sessionID: SessionID("s-1"), workspaceID: workspace.id, role: .workspace)
    }

    /// A workspace `starter`'s agent asked for, with the parentage on its row as `workspace_start`
    /// writes it.
    private func started(by starter: Workspace, named name: String, in store: Store) async throws -> Workspace {
        try await store.upsert(Workspace(
            repoID: starter.repoID, name: name, branch: "bloom/started-\(UUID().uuidString)",
            path: TestScratch.unique("worktree"), baseBranch: "main",
            origin: .agent(parentWorkspaceID: starter.id, spawnToolUseID: "toolu_rename")
        ))
    }

    // MARK: - Who may call it

    /// A workspace agent gets its own by default and may name another out loud. The owner must
    /// always name one because its connection is not sitting in a workspace.
    @Test("a workspace agent and the owner may call it")
    func roleGate() {
        let toolbox = BridgeToolbox(handlers: [WorkspaceRenameTool()])

        #expect(WorkspaceRenameTool().roles == [.workspace, .owner])
        #expect(toolbox.tools(for: .workspace).map(\.name) == ["workspace_rename"])
        #expect(toolbox.tools(for: .owner).map(\.name) == ["workspace_rename"])
    }

    @Test("it is served by a Bloom with no app behind it, because a name is one column of one row")
    func isInTheStandardToolbox() {
        let names = BridgeToolbox.standard.tools(for: .workspace).map(\.name)
        #expect(names.contains("workspace_rename"))
        #expect(BridgeToolbox.standard.tools(for: .owner).map(\.name).contains("workspace_rename"))
    }

    /// The reason it must not ask is the bug it was written from: an agent nine commits into a
    /// piece of work stopped and asked the owner to rename the workspace by hand, and an ask on
    /// this from a workspace agent running unattended is a hung turn spent on a label.
    @Test("Bloom answers its own permission question about it")
    func selfApproved() {
        #expect(BridgeToolApproval.isSelfApproved(
            toolName: "\(BridgeToolApproval.toolPrefix)workspace_rename"
        ))
        // The neighbours it is weighed against, so the line stays visible from here.
        #expect(BridgeToolApproval.selfApproved.contains("pane_rename"))
        #expect(!BridgeToolApproval.selfApproved.contains("quick_prompt_update"))
    }

    // MARK: - What a name has to be

    /// One rule at both doors. A name `workspace_start` would take and this would refuse is a
    /// workspace an agent can create and then cannot correct.
    @Test("a name is trimmed, and blank is nothing, exactly as workspace_start reads one")
    func theNameRule() {
        #expect(WorkspaceName.given("  App redesign  ") == "App redesign")
        #expect(WorkspaceName.given("App redesign") == "App redesign")
        #expect(WorkspaceName.given(nil) == nil)
        #expect(WorkspaceName.given("") == nil)
        #expect(WorkspaceName.given("   \n\t ") == nil)
    }

    @Test("a blank name is refused with a sentence rather than quietly ignored")
    func blankNameIsRefused() async throws {
        let store = try makeTestStore("rename-blank")
        let workspace = try await seed(store)

        for blank in ["", "   ", "\n"] {
            let result = await WorkspaceRenameTool().call(
                request(["name": .string(blank)]), as: agent(workspace), store: store
            )
            #expect(result.isError)
            #expect(result.text.contains("cannot be blank"))
        }

        // A name argument that is not a string at all reads as no name, not as a name of "".
        let missing = await WorkspaceRenameTool().call(
            request([:]), as: agent(workspace), store: store
        )
        #expect(missing.isError)

        #expect(try await store.workspace(id: workspace.id)?.name == "test")
    }

    @Test("the name is stored trimmed")
    func storedTrimmed() async throws {
        let store = try makeTestStore("rename-trim")
        let workspace = try await seed(store)

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("  App redesign\n")]), as: agent(workspace), store: store
        )

        #expect(!result.isError)
        #expect(try await store.workspace(id: workspace.id)?.name == "App redesign")
    }

    // MARK: - A workspace agent renames its own, or another it names

    @Test("a workspace agent renames the workspace its token speaks for")
    func agentRenamesItsOwn() async throws {
        let store = try makeTestStore("rename-own")
        let workspace = try await seed(store)

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign")]), as: agent(workspace), store: store
        )

        #expect(!result.isError)
        #expect(try await store.workspace(id: workspace.id)?.name == "App redesign")

        let json = try answer(result)
        #expect(json["name"]?.stringValue == "App redesign")
        #expect(json["previous_name"]?.stringValue == "test")
        #expect(json["workspace_id"]?.stringValue == workspace.id.rawValue)
        #expect(json["renamed"]?.boolValue == true)
        // Nothing else moved, and the answer has to say so: a model that reads a rename as a
        // branch rename reports the wrong thing to the owner.
        #expect(json["branch"]?.stringValue == "bloom/redesign")
    }

    /// A coordinator is an ordinary workspace. Replacing it must not strand the names of the old
    /// coordinator or the role workspaces that coordinator created.
    @Test("a new coordinator renames workspaces created by a previous coordinator")
    func agentRenamesAnyNamedWorkspace() async throws {
        let store = try makeTestStore("rename-cross-workspace")
        let mine = try await seed(store)
        let previousCoordinator = try await store.upsert(Workspace(
            repoID: mine.repoID, name: "Old coordinator", branch: "b2",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        let role = try await started(by: previousCoordinator, named: "Web client", in: store)

        let coordinatorResult = await WorkspaceRenameTool().call(
            request([
                "name": .string("Bloom: Coordinator History"),
                "workspace": .string("old coordinator"),
            ]),
            as: agent(mine), store: store
        )
        #expect(!coordinatorResult.isError, "\(coordinatorResult.text)")
        #expect(try await store.workspace(id: previousCoordinator.id)?.name == "Bloom: Coordinator History")

        let roleResult = await WorkspaceRenameTool().call(
            request([
                "name": .string("Bloom: Web Client"),
                "workspace": .string(role.id.rawValue),
            ]),
            as: agent(mine), store: store
        )
        #expect(!roleResult.isError, "\(roleResult.text)")
        #expect(try await store.workspace(id: role.id)?.name == "Bloom: Web Client")
        #expect(try await store.workspace(id: mine.id)?.name == "test")
    }

    @Test("a shared name is ambiguous across all workspaces, and neither is touched")
    func namedWorkspaceIsAmbiguous() async throws {
        let store = try makeTestStore("rename-workspace-ambiguous")
        let mine = try await seed(store)
        let first = try await started(by: mine, named: "helper", in: store)
        let otherCoordinator = try await store.upsert(Workspace(
            repoID: mine.repoID, name: "other coordinator", branch: "b2",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        let second = try await started(by: otherCoordinator, named: "Helper", in: store)

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign"), "workspace": .string("helper")]),
            as: agent(mine), store: store
        )

        #expect(result.isError)
        #expect(result.text.contains(first.id.rawValue))
        #expect(result.text.contains(second.id.rawValue))
        #expect(try await store.workspace(id: first.id)?.name == "helper")
        #expect(try await store.workspace(id: second.id)?.name == "Helper")
    }

    @Test("an unknown workspace named by an agent is refused with the names there are")
    func agentNamesUnknownWorkspace() async throws {
        let store = try makeTestStore("rename-workspace-unknown")
        let mine = try await seed(store)

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign"), "workspace": .string("missing")]),
            as: agent(mine), store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("no workspace called 'missing'"))
        #expect(result.text.contains("test"))
    }

    /// The workspace was archived away underneath a turn that was still running in it. The
    /// refusal has to say the row is gone rather than blame the name, because there is no name in
    /// this call to fix.
    @Test("a token whose workspace is no longer in Bloom is told that, not told to try again")
    func parentWhoseRowHasGone() async throws {
        let store = try makeTestStore("rename-nowhere")
        _ = try await seed(store)

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign")]),
            as: BridgeIdentity(sessionID: SessionID("s"), workspaceID: WorkspaceID("gone"), role: .workspace),
            store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("no longer in Bloom"))
    }

    // MARK: - The owner names one out loud

    @Test("the owner must say which, because it is sitting in none")
    func ownerMustName() async throws {
        let store = try makeTestStore("rename-unnamed")
        _ = try await seed(store)

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign")]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("not sitting in one"))
    }

    @Test("the owner names one by its name, or by its id in any case")
    func ownerNamesByNameOrID() async throws {
        let store = try makeTestStore("rename-owner")
        let workspace = try await seed(store)

        let byName = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign"), "workspace": .string("TEST")]),
            as: .owner, store: store
        )
        #expect(!byName.isError)
        #expect(try await store.workspace(id: workspace.id)?.name == "App redesign")

        let byID = await WorkspaceRenameTool().call(
            request([
                "name": .string("App redesign, second pass"),
                "workspace": .string(workspace.id.rawValue.uppercased()),
            ]),
            as: .owner, store: store
        )
        #expect(!byID.isError)
        #expect(try await store.workspace(id: workspace.id)?.name == "App redesign, second pass")
    }

    @Test("a name nothing answers to is refused with the names there are")
    func unknownName() async throws {
        let store = try makeTestStore("rename-unknown")
        _ = try await seed(store)

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign"), "workspace": .string("redesign")]),
            as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("no workspace called 'redesign'"))
        #expect(result.text.contains("test"))
        #expect(result.text.contains("workspace_list"))
    }

    /// Guessing here means renaming a workspace the caller did not name, which is the one outcome
    /// a rename tool must not have.
    @Test("a name two workspaces share is refused, and neither is touched")
    func ambiguousName() async throws {
        let store = try makeTestStore("rename-ambiguous")
        let first = try await seed(store)
        let second = try await store.upsert(Workspace(
            repoID: first.repoID, name: "test", branch: "b2",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign"), "workspace": .string("test")]),
            as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("2 workspaces are called 'test'"))
        #expect(result.text.contains(first.id.rawValue))
        #expect(result.text.contains(second.id.rawValue))
        #expect(try await store.workspace(id: first.id)?.name == "test")
        #expect(try await store.workspace(id: second.id)?.name == "test")
    }

    /// The archive lists workspaces by name too, and one somebody finished and mislabelled is
    /// exactly the one worth correcting. Being refused for a row that is plainly on the screen is
    /// the worse answer.
    @Test("an archived workspace can still be renamed")
    func archivedIsStillNameable() async throws {
        let store = try makeTestStore("rename-archived")
        let workspace = try await seed(store)
        try await store.update(workspaceID: workspace.id) { $0.archive() }

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign"), "workspace": .string("test")]),
            as: .owner, store: store
        )

        #expect(!result.isError)
        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.name == "App redesign")
        #expect(stored.state == .archived)
    }

    // MARK: - What it costs to undo, and what it must not disturb

    /// The field that makes the tool self-approved: an undo that costs one call.
    @Test("the answer carries the previous name, and calling again with it puts the name back")
    func theUndo() async throws {
        let store = try makeTestStore("rename-undo")
        let workspace = try await seed(store)

        let renamed = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign")]), as: agent(workspace), store: store
        )
        let was = try #require(try answer(renamed)["previous_name"]?.stringValue)
        #expect(renamed.text.contains("call workspace_rename again with 'test'"))

        let undone = await WorkspaceRenameTool().call(
            request(["name": .string(was)]), as: agent(workspace), store: store
        )

        #expect(!undone.isError)
        #expect(try await store.workspace(id: workspace.id)?.name == "test")
    }

    /// `InPlaceRename` discards an unchanged name in the sidebar for the same reason: an identical
    /// UPDATE still fires the store's update hook, so it would spend every observer a reload to
    /// change nothing. Not a refusal, because the caller asked for a state the row is already in.
    @Test("a name the workspace already has writes nothing and says so")
    func unchangedNameWritesNothing() async throws {
        let store = try makeTestStore("rename-unchanged")
        let workspace = try await seed(store, named: "App redesign")

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign")]), as: agent(workspace), store: store
        )

        #expect(!result.isError)
        let json = try answer(result)
        #expect(json["renamed"]?.boolValue == false)
        #expect(json["name"]?.stringValue == "App redesign")
        #expect(json["previous_name"]?.stringValue == "App redesign")
        #expect(result.text.contains("nothing was written"))
    }

    /// The bug `Store.update(workspaceID:)` exists for, in the sequence that produces it: a diff
    /// stat refresh writes every six seconds, and a rename that carried a whole value read before
    /// it would put the old numbers back. See `WorkspaceWriteIsolationTests`.
    @Test("a rename changes the name and no other column")
    func renameIsIsolated() async throws {
        let store = try makeTestStore("rename-isolation")
        let workspace = try await seed(store)

        try await store.updateDiffStat(
            workspaceID: workspace.id, additions: 41, deletions: 7, files: 3
        )
        try await store.touch(workspaceID: workspace.id, unread: true)
        try await store.update(workspaceID: workspace.id) { $0.pinned = true }

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign")]), as: agent(workspace), store: store
        )
        #expect(!result.isError)

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.name == "App redesign")
        #expect(stored.additions == 41)
        #expect(stored.deletions == 7)
        #expect(stored.changedFiles == 3)
        #expect(stored.unread)
        #expect(stored.pinned)
        #expect(stored.branch == "bloom/redesign")
        #expect(stored.path == workspace.path)
    }

    /// The automatic namer answers seconds into the first turn, which is exactly when an agent
    /// that has read the task is likeliest to call this. `WorkspaceNaming.mayApplyName` compares
    /// against the exact codename handed over, so a name written here stops it dead. It was
    /// written for a person renaming the row while the model was thinking; this is the same event
    /// through another door.
    @Test("a rename shuts the automatic namer out, the way typing over the row does")
    func automaticNamingCannotOverwriteIt() async throws {
        let store = try makeTestStore("rename-namer")
        let placeholder = "Foxglove"
        let workspace = try await seed(store, named: placeholder)

        #expect(WorkspaceNaming.mayApplyName(current: placeholder, placeholder: placeholder))

        let result = await WorkspaceRenameTool().call(
            request(["name": .string("App redesign")]), as: agent(workspace), store: store
        )
        #expect(!result.isError)

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(!WorkspaceNaming.mayApplyName(current: stored.name, placeholder: placeholder))
    }

    // MARK: - Which workspace a name means

    /// One answer for both tools that resolve a workspace a caller named, so `reveal` and this
    /// cannot come to disagree about which one the owner meant.
    @Test("the lookup takes an id in any case, a name in any case, and refuses a shared name")
    func theLookup() {
        let repo = Repo(name: "bloom", path: "/tmp/bloom")
        let first = Workspace(
            repoID: repo.id, name: "App redesign", branch: "b1", path: "/p1", baseBranch: "main"
        )
        let second = Workspace(
            repoID: repo.id, name: "app redesign", branch: "b2", path: "/p2", baseBranch: "main"
        )
        let other = Workspace(
            repoID: repo.id, name: "Sentry importer", branch: "b3", path: "/p3", baseBranch: "main"
        )

        #expect(BridgeWorkspaceLookup.find(other.id.rawValue, among: [first, other]) == .found(other))
        #expect(
            BridgeWorkspaceLookup.find(other.id.rawValue.uppercased(), among: [first, other])
                == .found(other)
        )
        #expect(BridgeWorkspaceLookup.find("SENTRY IMPORTER", among: [first, other]) == .found(other))
        #expect(BridgeWorkspaceLookup.find("  ", among: [first, other]) == .unknown)
        #expect(BridgeWorkspaceLookup.find("nothing", among: [first, other]) == .unknown)
        #expect(
            BridgeWorkspaceLookup.find("app redesign", among: [first, second, other])
                == .ambiguous([first, second])
        )
    }
}

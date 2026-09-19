import Testing
@testable import BloomClient

/// Which Bloom Cloud workspaces an agent on this Mac may reach, which is what `workspace_list`
/// lists: only what the signed-in person could open themselves.
@Suite("Bloom Cloud workspaces an agent on this Mac may reach")
struct CloudWorkspaceBridgeReachTests {
    private func item(_ id: String, state: String = "idle", role: String? = "owner", canOpen: Bool = true, archived: Bool = false) -> CloudWorkspaceItem {
        CloudWorkspaceItem(
            id: id, teamID: "t1", name: id, branch: "b", state: state, role: role, canOpen: canOpen,
            archivedAt: archived ? .now : nil
        )
    }

    @Test("one the person owns or was shared is reachable")
    func reachable() {
        #expect(item("mine").isReachableFromBridge)
        #expect(item("shared", role: "collaborator").isReachableFromBridge)
    }

    /// An owner or admin is sent a teammate's private workspace to see and archive, not to open.
    @Test("a teammate's private workspace, and an archived or archiving one, are not")
    func unreachable() {
        let items = [
            item("private", role: nil, canOpen: false),
            item("archived", archived: true),
            item("archiving", state: "archiving"),
            item("gone", state: "archived"),
            item("mine"),
        ]
        #expect(items.filter(\.isReachableFromBridge).map(\.id) == ["mine"])
    }
}

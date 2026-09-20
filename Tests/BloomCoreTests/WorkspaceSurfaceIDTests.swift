import BloomCore
import Foundation
import Testing

/// The key the per-workspace stores file a workspace's tabs, order and read marks under.
@Suite("Workspace surface id")
struct WorkspaceSurfaceIDTests {
    /// The load-bearing one: a local workspace's key is its id, unchanged, so keying the tab
    /// stores by a surface rather than by a workspace needs no migration and loses nobody's tabs.
    @Test("a local workspace's key is its id")
    func localKeyIsTheID() {
        let id = WorkspaceID("01K5ABCDEF")
        #expect(WorkspaceSurfaceID.local(id).storageKey == id.rawValue)
        #expect(TabDefaults.tabListKey(.local(id)) == "center.tabs.01K5ABCDEF")
        #expect(TabDefaults.stripKey(.local(id)) == "center.strip.01K5ABCDEF")
    }

    /// And a Cloud workspace cannot read a local one's, whatever its id happens to be.
    @Test("a Cloud workspace is namespaced apart")
    func cloudIsNamespaced() {
        let shared = "01K5ABCDEF"
        let local = WorkspaceSurfaceID.local(WorkspaceID(shared))
        let cloud = WorkspaceSurfaceID.cloud(CloudWorkspaceID(shared))
        #expect(cloud.storageKey != local.storageKey)
        #expect(cloud.storageKey == "cloud:" + shared)
        #expect(cloud.local == nil)
        #expect(local.local == WorkspaceID(shared))
    }

    /// The bytes, because this is written into every stored `CenterTab`. A local workspace's
    /// record is the same string it always was, so a tab list from a previous version reads back
    /// naming the same workspace rather than being dropped.
    @Test("it is stored as one string, and an old record still reads")
    func codingIsOneString() throws {
        let local = WorkspaceSurfaceID.local(WorkspaceID("01K5ABCDEF"))
        let encoded = try JSONEncoder().encode(local)
        #expect(String(data: encoded, encoding: .utf8) == "\"01K5ABCDEF\"")
        #expect(try JSONDecoder().decode(WorkspaceSurfaceID.self, from: encoded) == local)

        let cloud = WorkspaceSurfaceID.cloud(CloudWorkspaceID("01K5CLOUD"))
        let cloudBytes = try JSONEncoder().encode(cloud)
        #expect(String(data: cloudBytes, encoding: .utf8) == "\"cloud:01K5CLOUD\"")
        #expect(try JSONDecoder().decode(WorkspaceSurfaceID.self, from: cloudBytes) == cloud)
    }
}

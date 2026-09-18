import Foundation
import Testing
@testable import BloomClient

@Suite("A Cloud workspace's web address, as runbloom.app gives it")
struct CloudWorkspaceItemURLTests {
    private func item(_ json: String) throws -> CloudWorkspaceItem {
        try JSONDecoder().decode(CloudWorkspaceItem.self, from: Data(json.utf8))
    }

    @Test("taken as given when the server sends it, and absent from one that does not")
    func passedThrough() throws {
        let given = try item(#"{"id":"01k5","state":"setting_up","url":"https://runbloom.app/app/spatie/workspaces/01k5"}"#)
        #expect(given.url == "https://runbloom.app/app/spatie/workspaces/01k5")
        #expect(try item(#"{"id":"01k5","state":"setting_up"}"#).url == nil)
    }
}

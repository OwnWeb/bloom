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

    @Test("personal colour and project API details are taken as given")
    func workspaceActions() throws {
        let given = try item("""
        {"id":"01k5","state":"idle","colour":"4C8DF6","can_colour":true,
         "colour_url":"https://runbloom.app/api/v1/cloud-workspaces/01k5/mark",
         "project":{"id":"p1","repository":"spatie/bloom",
                    "settings_url":"https://runbloom.app/api/v1/teams/t1/projects/p1/settings"}}
        """)
        #expect(given.colour == "4C8DF6")
        #expect(given.canColour)
        #expect(given.colourURL == "https://runbloom.app/api/v1/cloud-workspaces/01k5/mark")
        #expect(given.project?.settingsURL == "https://runbloom.app/api/v1/teams/t1/projects/p1/settings")

        let old = try item(#"{"id":"01k5","state":"idle","project":{"id":"p1","repository":"spatie/bloom"}}"#)
        #expect(old.colour == nil)
        #expect(!old.canColour)
        #expect(old.colourURL == nil)
        #expect(old.project?.settingsURL == nil)
    }

    @Test("the current workspace notice wins, with the old runner key as a fallback")
    func workspaceNotice() throws {
        let current = try item("""
        {"id":"01k5","state":"idle",
         "workspace_notice":{"kind":"setup_never_started","message":"Setup did not begin."},
         "runner_notice":{"kind":"update_failed","message":"Old alias."}}
        """)
        #expect(current.workspaceNotice?.kind == CloudWorkspaceNotice.setupNeverStarted)
        #expect(current.workspaceNotice?.message == "Setup did not begin.")

        let legacy = try item("""
        {"id":"01k5","state":"idle",
         "runner_notice":{"kind":"update_rolled_back","message":"Running the previous version."}}
        """)
        #expect(legacy.workspaceNotice?.kind == CloudWorkspaceNotice.rolledBack)
    }
}

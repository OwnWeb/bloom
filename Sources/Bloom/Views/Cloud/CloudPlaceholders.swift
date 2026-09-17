import BloomClient
import BloomCore
import SwiftUI

struct CloudTerminalPane: View {
    var session: CloudWorkspaceSession
    var body: some View { Palette.windowBackground }
}

struct CloudChangesPane: View {
    var session: CloudWorkspaceSession
    var body: some View { Palette.windowBackground }
}

struct CloudSharePopover: View {
    var workspaceID: BloomCore.CloudWorkspaceID
    var item: BloomClient.CloudWorkspaceItem?
    var body: some View { EmptyView() }
}

import BloomClient
import BloomCore
import SwiftUI

/// What a Cloud workspace's row offers on a right click.
struct CloudWorkspaceMenuItems: View {
    var item: CloudWorkspaceItem
    @Environment(AppModel.self) private var app

    private var id: CloudWorkspaceID { CloudWorkspaceID(item.id) }

    var body: some View {
        if item.canOpen {
            Button("Open Preview in Browser") {
                app.selection = .cloud(id)
                Task { await app.cloud.session(for: id).openPreview() }
            }
        }
        if let repository = item.project?.repository, let url = URL(string: "https://github.com/\(repository)/tree/\(item.displayBranch)") {
            Button("Open Branch on GitHub") { NSWorkspace.shared.open(url) }
        }
        if item.canArchive {
            Divider()
            Button("Archive…") {
                app.selection = .cloud(id)
                // The menu was opened on the row, so the row is the thing to hang it on.
                app.cloud.askToArchive(id, from: .row)
            }
        }
    }
}

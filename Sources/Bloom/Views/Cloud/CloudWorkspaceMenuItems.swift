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
        if let settings = CloudProjectSettingsAction(project: item.project) {
            // The default browser owns its own runbloom.app sign in. This stays outside the Cloud
            // preview pane, so opening settings cannot move or persist any tab or split.
            Button(MenuBarCatalogue[.projectSettings].title) {
                NSWorkspace.shared.open(settings.url)
            }
        }
        if item.canColour, item.colourURL != nil {
            CloudWorkspaceColourItem(item: item, cloud: app.cloud)
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

/// The same personal palette as a workspace on this Mac, written through runbloom.app.
private struct CloudWorkspaceColourItem: View {
    var item: CloudWorkspaceItem
    var cloud: CloudWorkspaces

    var body: some View {
        Picker(MenuBarCatalogue[.colour].title, selection: selection) {
            Text("None").tag("")
            ForEach(WorkspaceColour.all) { colour in
                Label {
                    Text(colour.name)
                } icon: {
                    if let swatch = WorkspaceColourImage.of(colour.hex) {
                        Image(nsImage: swatch).renderingMode(.original)
                    }
                }
                .tag(colour.hex)
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { item.colour ?? "" },
            set: { hex in
                Task { await cloud.setColour(hex.isEmpty ? nil : hex, for: CloudWorkspaceID(item.id)) }
            }
        )
    }
}

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
        if let project = item.project,
           let icon = app.cloud.projectIcons.state(
               for: .init(teamID: CloudTeamID(item.teamID), projectID: CloudProjectID(project.id)),
               settingsEndpoint: project.settingsURL
           ) {
            CloudProjectIconMenu(item: item, icon: icon, cloud: app.cloud)
        }
        if item.canColour, item.colourURL != nil {
            CloudWorkspaceColourItem(item: item, cloud: app.cloud)
        }
        if item.canArchive {
            Divider()
            Button("Delete Workspace…", role: .destructive) {
                app.selection = .cloud(id)
                // The menu was opened on the row, so the row is the thing to hang it on.
                app.cloud.askToArchive(id, from: .row)
            }
        }
    }
}

/// Discovery status and the authorised refresh action for a Cloud project's shared mark.
private struct CloudProjectIconMenu: View {
    var item: CloudWorkspaceItem
    var icon: RunbloomProjectSettings.Icon
    var cloud: CloudWorkspaces

    var body: some View {
        Menu {
            Label(status.title, systemImage: status.symbol)
                .disabled(true)
            if let refreshURL = icon.refreshURL, cloud.api.allowsAPIEndpoint(refreshURL) {
                Divider()
                Button("Check Again") { Task { await cloud.refreshProjectIcon(for: item) } }
                    .accessibilityLabel("Check for a new project icon")
            }
        } label: {
            Label("Project Icon", systemImage: "photo")
        }
        .accessibilityValue(status.accessibilityValue)
    }

    private var status: (title: String, symbol: String, accessibilityValue: String) {
        switch icon.status {
        case "available": ("Artwork available", "checkmark", "Artwork available")
        case "missing": ("Using initials", "textformat", "No artwork found, using initials")
        case "pending": ("Check pending", "clock", "Project icon check pending")
        default: ("Status unavailable", "questionmark", "Project icon status unavailable")
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

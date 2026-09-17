import SwiftUI
import BloomCore

/// The detail column's toolbar. The sidebar draws its own toggle while it is open, grouped with
/// New (see `SidebarView`), so this one draws a toggle only while the sidebar is folded. Search and the inspector use standard toolbar buttons; only the
/// pull request band needs a title-bar accessory to follow the inspector's width.
struct BloomWindowToolbar: ToolbarContent {
    let app: AppModel
    let isSidebarFolded: Bool
    /// Whether the share popover is open. Here rather than in the item, because a `ToolbarContent`
    /// is a value the window rebuilds and a popover anchored to state inside it closes itself.
    @Binding var isSharingCloudWorkspace: Bool

    var body: some ToolbarContent {
        if isSidebarFolded {
            ToolbarItem(placement: .navigation) {
                SidebarToggleButton()
            }
        }

        ToolbarItem(placement: .navigation) {
            WindowTitleControl(app: app)
                .padding(.leading, Metrics.spacingWide)
        }
        // The editable window title is text, so it does not need a button's background.
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible, placement: .navigation)

        ToolbarItem(placement: .primaryAction) {
            Button("Search", systemImage: "magnifyingglass") {
                SearchPanelModel.shared.open(app: app)
            }
            .help("Search workspaces, transcripts and commands")
        }

        // Between Search and the inspector toggle: the inspector toggle keeps the window's edge the
        // way the sidebar toggle keeps the other one, and `+` sits in the middle of the group, as
        // asked for. Only on a workspace: Home and Ask Bloom have no centre column to open a tab
        // in, and a `+` that does nothing there is worse than none.
        // `selectedModel` rather than `selectedWorkspace`, because the menu acts on the model and
        // a model not prepared yet has nothing for it to act on.
        if let workspace = app.selectedModel, app.selectedWorkspace != nil {
            ToolbarItem(placement: .primaryAction) {
                NewTabMenu(model: workspace)
            }
        }

        // What a Cloud workspace has and a local one has no answer to: who else is here, the
        // preview and sharing. See `CloudWorkspaceControls`.
        if let id = app.selection.cloudWorkspaceID {
            CloudWorkspaceControls(
                session: app.cloud.session(for: id),
                item: app.selectedCloudWorkspace,
                isSharing: $isSharingCloudWorkspace
            )
        }

        // The same `+`, from the same menu, for a workspace on a machine. It opens the same kinds
        // of tab, which is why the strip below it is the app's own strip as well.
        if let id = app.selection.cloudWorkspaceID, app.selectedCloudWorkspace?.canOpen == true {
            ToolbarItem(placement: .primaryAction) {
                CloudNewTabMenu(session: app.cloud.session(for: id))
            }
        }

        if app.isInspectorPresented || app.selectedWorkspace != nil || app.selection.cloudWorkspaceID != nil {
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") {
                    app.isInspectorVisible.toggle()
                }
                .accessibilityValue(app.isInspectorVisible ? "Shown" : "Hidden")
                .help(app.isInspectorVisible ? "Hide the changed files" : "Show the changed files")
            }
        }
    }
}

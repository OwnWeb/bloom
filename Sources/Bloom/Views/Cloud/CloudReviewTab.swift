import BloomCore
import SwiftUI

/// A Cloud workspace's review tab: the changed files on the left, the chosen file's diff beside
/// them.
///
/// **Both halves are the app's own.** `ChangedFileList` and `DiffView` are generic over
/// `WorkspaceReviewSurface`, so the rows, the counts, the filter, the read ticks, the context
/// menus, the hunks, the expanders, Discard and the whole diff toolbar are the ones a local
/// workspace has. What a Cloud workspace cannot do is a capability rather than a branch: the
/// gutter `+` and the in-place editor are not drawn, and the header bar says why.
///
/// The arrangement is still this view's. The centre column's own `ReviewPaneView`, with its tab,
/// its pinning and its composer, is the next slice; until then a Cloud workspace's review is one
/// pane with a list beside it. See the plan in docs/REMOTE-WORKSPACES.md.
struct CloudReviewTab: View {
    var session: CloudWorkspaceSession

    var body: some View {
        HSplitView {
            ChangedFileList(model: session)
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 460)
            diffPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await session.refreshChanges() }
    }

    @ViewBuilder
    private var diffPane: some View {
        if let file = selected {
            DiffView(model: session, file: file)
                // Rebuilt per file, which is what the centre column's review does with its own
                // tab: a diff view holds the file it was made for.
                .id(file.id)
        } else {
            EmptyStateView(
                glyph: "plusminus",
                title: "Nothing selected",
                message: "Choose a file to see what changed in it."
            )
        }
    }

    private var selected: ChangedFile? {
        guard let path = session.selectedFilePath else { return nil }
        return session.changedFiles.first { $0.path == path && $0.layer == session.selectedChangeLayer }
            ?? session.changedFiles.first { $0.path == path }
    }
}

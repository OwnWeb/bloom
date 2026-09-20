import AppKit
import BloomCore
import SwiftUI

extension CloudWorkspaceSession {
    /// What a tool tab of a Cloud workspace fills a pane with. The kinds are the machine's: its
    /// own terminal, the review of what its agent changed, and the setup output, which is the only
    /// account of a machine's first few minutes.
    ///
    /// Handed back by the workspace for the reason the editor pane is: the strip, the panes, the
    /// splits and the menus around it are one view over both kinds, and what a tool tab IS is the
    /// one thing that genuinely differs. See `WorkspaceSurface.toolPane`.
    @ViewBuilder
    func toolPane(
        for tab: CenterTab,
        siblings: [PaneContent],
        splitColumn: @escaping @MainActor (SplitAxis, PaneKind) -> Void,
        paneMenu: (@MainActor () -> NSMenu)?
    ) -> some View {
        switch tab.kind {
        case .terminal:
            CloudTerminalPane(session: self)
        case .review:
            // The app's own review pane: the same toolbar, the same All files and one file, the
            // same diff and the same composer under it. See `ReviewPaneView`.
            ReviewPaneView(model: self, tab: tab, siblings: siblings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .browser:
            // The machine's own app, in a pane. Not the local browser tab: see `CloudPreviewPane`
            // for why a window onto one machine cannot have an address bar.
            CloudPreviewPane(session: self)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notes:
            // The machine's note, in the local pane. It is the workspace's scratchpad rather than
            // this Mac's, which is what lets somebody else on the team open the workspace and read
            // what was written in it. See `CloudNotesPane`.
            CloudNotesPane(session: self)
                .id(id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .setup:
            // Not a kind a Cloud workspace opens: setup is a row at the head of the conversation
            // rather than a tab. A tab of it was written by another version of Bloom, so it says so
            // rather than drawing an empty pane. `CenterTabStore` drops these on the way in, so
            // this is the belt to that brace.
            EmptyStateView(
                glyph: "questionmark.square.dashed",
                title: "Nothing to show",
                message: "This tab was made by a newer version of Bloom than this one."
            )
        }
    }
}

import SwiftUI

/// The inspector column's stable root: what the agent changed.
///
/// Structural stability is the whole point of this type. When the inspector's content was written
/// inline as `if let model { InspectorView(...).inspectorColumnWidth(...) }`, the column width
/// modifier itself came and went as the selection resolved, so AppKit kept adding and removing the
/// column's constraints and recreating the hosted platform view. That is an unbounded Update
/// Constraints loop, and it crashed the window. Here the pane is always the same view, the width
/// is always applied, and only what is drawn inside changes.
///
/// It used to carry a terminal panel under the file list, holding the setup log, the run scripts
/// and a strip of shells. All three have somewhere better to be: a terminal is a tab in the centre
/// column like any other, the setup log is a row in the transcript that unfolds where the reader
/// already is, and a run script opens a terminal tab of its own from the Workspace menu. What is
/// left here is the one question this column answers.
struct InspectorPane: View {
    let model: WorkspaceModel?
    /// The Cloud workspace on screen, when that is what the window is showing. One of the two is
    /// nil: the column draws the same `InspectorView` over whichever it was handed, because that
    /// view is generic over `WorkspaceSurface` rather than over a kind of workspace.
    var cloud: CloudWorkspaceSession?
    @Environment(AppModel.self) private var app

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            InspectorView(model: model)
                .disabled(app.isArchiving(model.workspace.id))
                // Rebuilt per workspace, so a diff selection never leaks across a switch.
                .id(model.workspace.id)
        } else if let cloud {
            InspectorView(model: cloud)
                .id(cloud.id)
        } else if app.selection.cloudWorkspaceID != nil {
            // A Cloud workspace is selected and there is no session to draw over: the list has not
            // arrived yet, or this account cannot open it. Either way something IS selected, and
            // saying nothing is says the opposite of what the window next to it says.
            EmptyStateView(
                glyph: "sidebar.right",
                title: "Nothing to show yet",
                message: "This Bloom Cloud workspace has not opened. Its changes appear here when it does."
            )
        } else {
            EmptyStateView(
                glyph: "sidebar.right",
                title: "No workspace selected",
                message: "Pick a workspace to see what its agent changed."
            )
        }
    }
}

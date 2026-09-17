import BloomCore
import SwiftUI

extension CloudWorkspaceSession {
    /// What Edit mode would show for a Cloud workspace, which is the sentence saying why there is
    /// nothing to edit here.
    ///
    /// It is drawn rather than left out because nothing reaches it: `.editFiles` is missing, so the
    /// bar offers no Edit and the mode cannot be selected. If a route to it is ever added, this is
    /// what that route finds, rather than a blank pane. See `WorkspaceModel.editorPane(path:session:)`.
    func editorPane(path: String, session: FileEditSession) -> some View {
        EmptyStateView(
            glyph: "square.and.pencil",
            title: "Not editable here",
            message: WorkspaceCapabilities.Capability.editFiles.cloudSentence
        )
    }
}

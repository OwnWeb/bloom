import BloomCore
import SwiftUI

extension CloudWorkspaceSession {
    /// The same editor a worktree gets, over the machine's own copy of the file.
    ///
    /// **It was a sentence saying this could not be done, and the sentence was about the pane
    /// rather than about the workspace.** Editing needs three things: the text, a way to write it
    /// back, and a guard that refuses a write made against a version somebody else has moved on
    /// from. The machine answers all three, and has all along: `file` sends the text with a
    /// revision, `write_file` carries that revision back, and the machine refuses the write where
    /// it no longer matches, which is the same guard `FileEditor` keeps for a file on this Mac.
    /// What was missing was a pane that could be handed a different place to read from. See
    /// `EditableFiles` and `MachineFiles`.
    func editorPane(path: String, session: FileEditSession) -> FileEditPane<CloudWorkspaceSession> {
        FileEditPane(model: self, path: path, session: session)
    }
}

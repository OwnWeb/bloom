import SwiftUI
import BloomCore

/// The window a Cloud workspace is started in.
///
/// A dedicated window for creating a Cloud workspace.
/// the two side by side and said the Cloud one looked like a different application: his was a modal
/// sheet with a four row form in it, Project, Name, Branch, From, and a First message box under
/// them, while a local workspace is started by writing a sentence into a composer. A form asks you
/// to fill in a record; the composer asks what you want to do and derives the record from it. Both
/// are the second thing now, with the same parts in the same places, and what differs between them
/// is only what is actually different: see `CreateCloudWorkspaceView`.
///
/// One window rather than one per project, which is where it parts from the local scene. That one
/// is keyed by `RepoID` because its `+` is on a project's own sidebar header; a Cloud workspace is
/// started from one button for the whole section, so there is one window and the project is chosen
/// inside it.
struct CreateCloudWorkspaceWindow: Scene {
    let model: AppModel

    /// The scene id. Opening it from anywhere is `openWindow(id:)` with it.
    static let id = "create-cloud-workspace"

    var body: some Scene {
        Window("New Bloom Cloud Workspace", id: Self.id) {
            CreateCloudWorkspaceView()
                .environment(model)
                // Cmd+W, and not Escape: the
                // composer's own completion menus take Escape first. See `WindowRoles`.
                .windowRole(.utility)
        }
        .windowResizability(.contentSize)
        // Nothing here is worth restoring: no machine has been asked for yet, and the draft would
        // come back at the next launch against a team list that is empty until runbloom.app
        // answers. The same verdict as the local create window.
        .restorationBehavior(.disabled)
    }
}

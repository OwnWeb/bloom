import SwiftUI

/// Whether this copy of a retained workspace column is the one the window is presenting.
///
/// The previous column stays laid out so returning to it is a swap rather than a transcript
/// rebuild. Work that exists only for a visible reader still has to stop while that column is
/// dormant, which is what this environment value tells it.
extension EnvironmentValues {
    @Entry var workspaceColumnActivity: WorkspaceColumnActivity?
}

/// Keeps observation of the activity flag out of an expensive parent's body.
struct WorkspaceColumnActivitySignal: View {
    @Environment(\.workspaceColumnActivity) private var activity
    var changed: @MainActor (Bool) -> Void

    var body: some View {
        Color.clear
            .onChange(of: activity?.isActive ?? true, initial: true) { _, active in
                changed(active)
            }
    }
}

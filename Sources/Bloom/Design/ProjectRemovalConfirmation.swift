import SwiftUI

extension View {
    /// Asks whether to remove a project, as a popover on the thing that asked.
    ///
    /// It was a `confirmationDialog` in two places, the sidebar's project header and the project's
    /// settings window, each spelling out the same buttons around the same `ProjectRemoval`
    /// words. On macOS that dialog is a sheet over the whole window, which put a question about one
    /// project in the middle of a window about all of them. The archive and discard confirmations
    /// are already popovers through `ConfirmationPopover`, so this is that shape rather than a third
    /// one, and Cancel having focus while Return confirms nothing comes with it.
    ///
    /// Driven by the question itself rather than by a flag, because the question is built when the
    /// control is pressed and held until it is answered. `AppModel.projectRemoval` filters the
    /// whole workspace list, and computing it in a `body` made every project header depend on that
    /// list, which `reload()` reassigns whenever any diff stat moves. See
    /// `RepoHeaderRow.askAboutRemoving`.
    ///
    /// Attach it to the control that asked. A context menu item has no control of its own that
    /// outlives the menu, so the sidebar attaches it to the row the menu belongs to.
    func projectRemovalConfirmation(
        _ removal: Binding<Confirmation?>,
        arrowEdge: Edge = .top,
        onConfirm: @escaping () -> Void
    ) -> some View {
        popover(isPresented: removal.isPresent(), arrowEdge: arrowEdge) {
            if let question = removal.wrappedValue {
                ConfirmationPopover(
                    title: question.title,
                    confirmLabel: question.confirmLabel,
                    tint: question.tone.color,
                    onConfirm: {
                        removal.wrappedValue = nil
                        onConfirm()
                    },
                    onCancel: { removal.wrappedValue = nil }
                ) {
                    Text(question.message)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

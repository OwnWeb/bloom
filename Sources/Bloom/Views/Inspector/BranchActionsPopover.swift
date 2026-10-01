import SwiftUI
import BloomCore

/// One compact confirmation before asking the agent to open a pull request.
struct BranchActionsPopover: View {
    let model: WorkspaceModel
    let onCreatePullRequest: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ConfirmationPopover(
            title: "Create pull request?",
            confirmLabel: "Create pull request",
            tint: Palette.controlAccent,
            onConfirm: {
                dismiss()
                onCreatePullRequest()
            },
            onCancel: { dismiss() }
        ) {
            Picker("Merge using", selection: mergeExecution) {
                ForEach(MergeExecution.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)

            Text("This choice is used when the pull request is ready to merge.")
                .foregroundStyle(.secondary)
        }
    }

    private var mergeExecution: Binding<MergeExecution> {
        Binding(get: { model.mergeExecution }, set: { model.chooseMergeExecution($0) })
    }
}

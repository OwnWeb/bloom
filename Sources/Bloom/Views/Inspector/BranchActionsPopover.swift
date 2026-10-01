import SwiftUI
import BloomCore

/// The no-PR state still exposes the merge choice, with its prerequisite visible.
struct BranchActionsPopover: View {
    let model: WorkspaceModel
    let onCreatePullRequest: () -> Void
    let onMergeLocally: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var confirmingLocalMerge = false

    var body: some View {
        Group {
            if confirmingLocalMerge {
                ConfirmationPopover(
                    title: "Merge \(model.workspace.branch) into local \(model.workspace.baseBranch)?",
                    confirmLabel: "Merge locally",
                    tint: Palette.controlAccent,
                    onConfirm: {
                        dismiss()
                        onMergeLocally()
                    },
                    onCancel: { confirmingLocalMerge = false },
                    width: 380
                ) {
                    Text("Bloom will merge the committed branch into the project's local \(model.workspace.baseBranch) checkout. Both checkouts must be clean. If Git reports conflicts, Bloom will abort the merge.")
                    Text("The workspace and its branch will remain available. Nothing will be pushed to a remote.")
                        .foregroundStyle(.secondary)
                }
            } else {
                actions
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Branch actions")
                .font(.headline)

            Text("\(model.workspace.branch) → \(model.workspace.baseBranch)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            Text("Create pull request")
                .font(.subheadline.weight(.medium))
            Text("Ask this workspace's agent to push the branch and open a pull request.")
            Button("Create pull request") {
                dismiss()
                onCreatePullRequest()
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.controlAccent)

            Divider()

            Text("Merge locally")
                .font(.subheadline.weight(.medium))
            Text("Merge committed work into the local \(model.workspace.baseBranch) checkout without GitHub.")
            Button("Merge locally") { confirmingLocalMerge = true }
                .buttonStyle(.bordered)

            Divider()

            Text("Merge pull request")
                .font(.subheadline.weight(.medium))
            Picker("Merge using", selection: mergeExecution) {
                ForEach(MergeExecution.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)

            Text(mergeAvailability)
                .foregroundStyle(model.pullRequestRefreshFailure == nil ? Palette.textSecondary : Palette.negative)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if model.pullRequestRefreshFailure != nil {
                Button(isRefreshing ? "Checking GitHub…" : "Retry GitHub") {
                    isRefreshing = true
                    Task {
                        await model.refreshPullRequest()
                        isRefreshing = false
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .environment(\.backgroundProminence, .standard)
        .foregroundStyle(Palette.textPrimary)
        .font(.body)
        .padding(20)
        .frame(width: 360)
    }

    private var mergeAvailability: String {
        if let failure = model.pullRequestRefreshFailure {
            return "Bloom could not check for a pull request: \(failure.message) Merge is available once GitHub refresh succeeds and finds one."
        }
        return "No pull request for this branch yet. Create one first, then choose Merge in this strip."
    }

    private var mergeExecution: Binding<MergeExecution> {
        Binding(
            get: { model.mergeExecution },
            set: { model.chooseMergeExecution($0) }
        )
    }
}

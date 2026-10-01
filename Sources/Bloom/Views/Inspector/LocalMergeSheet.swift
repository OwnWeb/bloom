import SwiftUI
import BloomCore

/// One deliberate choice between an agent turn and a deterministic local git merge.
struct LocalMergeSheet: View {
    let model: WorkspaceModel

    @Environment(\.dismiss) private var dismiss
    @State private var isLoadingChoice = true
    @State private var plan: LocalMergePlan?
    @State private var failure: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text("Merge workspace branch")
                .font(Typo.heading)

            Text("\(model.workspace.branch) → \(targetBranch)")
                .font(Typo.title)
                .textSelection(.enabled)

            Picker("How to merge", selection: mode) {
                ForEach(LocalMergeMode.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(isLoadingChoice)

            if model.localMergeMode == .agent {
                Text("The workspace agent will merge into the local target checkout. You can review its commands and handle conflicts in the conversation.")
            } else {
                Text("Bloom will run git merge in the local target checkout. If git reports conflicts, Bloom will try to abort the merge and show the error.")
            }

            Text("This changes \(targetBranch) on this Mac. It does not push, use GitHub, delete either branch, or switch this workspace's checkout.")
                .foregroundStyle(.secondary)

            if let plan {
                Text("Target checkout: \(plan.targetPath)")
                    .font(Typo.caption)
                    .textSelection(.enabled)
            } else if failure == nil {
                ProgressView("Checking both checkouts…")
            }

            if let failure {
                Text(failure)
                    .foregroundStyle(Palette.negative)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Check again") { Task { await prepare() } }
                    .disabled(isWorking)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(model.localMergeMode == .agent ? "Ask agent to merge" : "Merge into \(targetBranch)") {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.controlAccent)
                .disabled(plan == nil || isLoadingChoice || isWorking || model.isRunning)
            }
        }
        .padding(Metrics.pane)
        .frame(width: 480)
        .task {
            await model.loadLocalMergeMode()
            isLoadingChoice = false
            await prepare()
        }
    }

    private var targetBranch: String { plan?.target ?? model.workspace.baseBranch }
    private var mode: Binding<LocalMergeMode> {
        Binding(get: { model.localMergeMode }, set: { model.chooseLocalMergeMode($0) })
    }

    private func prepare() async {
        plan = nil
        failure = nil
        do {
            plan = try await LocalBranchMerger.shared.prepare(
                source: model.workspace.branch,
                target: model.workspace.baseBranch,
                in: model.workspace.path
            )
        } catch let error as LocalMergeFailure {
            failure = error.message
        } catch {
            failure = String(describing: error)
        }
    }

    private func submit() async {
        guard let plan, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        if model.localMergeMode == .agent {
            if let refusal = await model.requestAgentLocalMerge(plan) {
                failure = refusal
            } else {
                dismiss()
            }
            return
        }

        do {
            try await LocalBranchMerger.shared.merge(plan)
            model.pullRequestNotice = PullRequestNotice(
                tone: .info,
                title: "Merged locally",
                message: "\(plan.source) was merged into local \(plan.target). Nothing was pushed."
            )
            await model.refreshChanges(.requested)
            dismiss()
        } catch let error as LocalMergeFailure {
            failure = error.message
            self.plan = nil
        } catch {
            failure = String(describing: error)
            self.plan = nil
        }
    }
}

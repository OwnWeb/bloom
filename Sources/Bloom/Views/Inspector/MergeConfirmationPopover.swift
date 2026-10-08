import SwiftUI
import BloomCore

/// A confirmation attached to the merge control, keeping the chat and diff visible.
struct MergeConfirmationPopover: View {
    let pullRequest: PullRequest
    let baseBranch: String
    let localWork: LocalWork?
    let method: GitHub.MergeMethod
    let deletesBranch: Bool
    let canMerge: Bool
    /// The fill of the merge control this is attached to, so the press that asks and the press
    /// that answers are one colour. It was `Palette.positive` for every state, which put a green
    /// button under an amber "Checks running" one and made the popover read as a second decision.
    let tint: Color
    /// The squash commit message, or nil for any other method or one left as proposed.
    let onConfirm: (SquashCommitMessage?) -> Void
    let onCancel: () -> Void

    @State private var subject = ""
    @State private var messageBody = ""

    private var proposed: SquashCommitMessage { .proposed(for: pullRequest) }

    var body: some View {
        ConfirmationPopover(
            title: pullRequest.mergeConfirmationTitle(base: baseBranch),
            confirmLabel: method.label,
            tint: tint,
            canConfirm: canMerge,
            onConfirm: {
                let message = SquashCommitMessage(subject: subject, body: messageBody)
                onConfirm(method == .squash && message.instruction(proposed: proposed) != nil ? message : nil)
            },
            onCancel: onCancel
        ) {
            if method == .squash {
                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    TextField("Commit subject", text: $subject)
                        .textFieldStyle(.roundedBorder)
                    TextField("Commit body, empty for \(pullRequest.forge.name)'s own", text: $messageBody, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)
                }
                .onAppear { subject = proposed.subject }
            }

            ForEach(pullRequest.mergeWarnings(base: baseBranch, local: localWork), id: \.self) { warning in
                Text(warning)
                    .foregroundStyle(Palette.negative)
            }

            Text(pullRequest.mergeConfirmationMessage)

            if let deletion = pullRequest.mergeBranchDeletionMessage(deletesBranch: deletesBranch) {
                Text(deletion)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

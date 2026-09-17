import BloomClient
import BloomCore
import SwiftUI

/// Confirming that a Cloud workspace is archived, which deletes its machine and its conversation.
///
/// Always asked, whatever the owner's "confirm before archiving" setting says: that setting is
/// about a local worktree whose branch survives it, and nothing about a Cloud workspace survives.
struct CloudArchiveSheet: View {
    var id: CloudWorkspaceID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: CloudArchiveConfirmation?
    @State private var isArchiving = false
    @State private var failure: String?

    private var name: String { app.cloud.item(id)?.displayName ?? "this Cloud workspace" }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Archive \(name)?")
                .font(.headline)
            if let confirmation {
                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    ForEach(confirmation.losses, id: \.self) { loss in
                        Label {
                            Text(loss).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: loss == CloudArchiveConfirmation.conversationSentence ? "bubble.left.and.exclamationmark.bubble.right" : "exclamationmark.triangle")
                                .foregroundStyle(Palette.warning)
                        }
                    }
                }
            } else {
                HStack(spacing: Metrics.spacingWide) {
                    ProgressView().controlSize(.small)
                    Text("Checking what would be lost…")
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Archive", role: .destructive) {
                    guard let confirmation else { return }
                    isArchiving = true
                    Task {
                        defer { isArchiving = false }
                        switch await app.cloud.archive(id, confirmed: confirmation) {
                        case .archived: dismiss()
                        case .moved(let fresh):
                            self.confirmation = fresh
                            failure = "Something changed in the Cloud workspace since this was checked. Read it again before archiving."
                        case .failed(let message): failure = message
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirmation == nil || isArchiving)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { confirmation = await app.cloud.archiveConfirmation(id) }
    }
}

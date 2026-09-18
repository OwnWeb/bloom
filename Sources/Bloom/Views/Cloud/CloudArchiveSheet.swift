import BloomClient
import BloomCore
import SwiftUI

/// Confirming that a Cloud workspace is archived, which deletes its machine and its conversation.
///
/// Always asked, whatever the owner's "confirm before archiving" setting says: that setting is
/// about a local worktree, whose conversation stays in this Mac's database after it goes. An
/// archived Cloud workspace keeps nothing but its branch on GitHub, and the sheet says both halves
/// of that in the app's own voice: the conversation first, because it is the thing nobody expects
/// to lose, and then what survives, so the loss is not read as bigger than it is.
struct CloudArchiveSheet: View {
    var id: CloudWorkspaceID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Where the sheet is, as one value rather than three flags that could disagree: a sheet that
    /// was archiving and had failed and had no confirmation was a state the flags could describe
    /// and nothing could draw.
    private enum Phase {
        /// Asking the machine, or runbloom.app when the machine cannot be asked, what would go.
        case checking
        case ready(CloudArchiveConfirmation, failure: String? = nil)
        case archiving(CloudArchiveConfirmation)

        var confirmation: CloudArchiveConfirmation? {
            switch self {
            case .checking: nil
            case .ready(let confirmation, _), .archiving(let confirmation): confirmation
            }
        }
    }

    @State private var phase = Phase.checking

    private var name: String { app.cloud.item(id)?.displayName ?? "this Cloud workspace" }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Archive \(name)?")
                .font(.headline)
            if let confirmation = phase.confirmation {
                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    ForEach(confirmation.losses, id: \.self) { loss in
                        line(loss, glyph: loss == CloudArchiveConfirmation.conversationSentence
                             ? "bubble.left.and.exclamationmark.bubble.right" : "exclamationmark.triangle",
                             tint: Palette.warning)
                    }
                    line(CloudArchiveConfirmation.survivesSentence, glyph: "arrow.triangle.branch", tint: Palette.textSecondary)
                }
            } else {
                HStack(spacing: Metrics.spacingWide) {
                    ProgressView().controlSize(.small)
                    Text("Checking what would be lost…")
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            if case .ready(_, let failure?) = phase {
                Text(failure)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Archive", role: .destructive, action: archive)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isArchivable)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { phase = .ready(await app.cloud.archiveConfirmation(id)) }
    }

    private var isArchivable: Bool {
        if case .ready = phase { true } else { false }
    }

    private func line(_ text: String, glyph: String, tint: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: glyph).foregroundStyle(tint)
        }
    }

    private func archive() {
        guard case .ready(let confirmation, _) = phase else { return }
        phase = .archiving(confirmation)
        Task {
            switch await app.cloud.archive(id, confirmed: confirmation) {
            case .archived:
                dismiss()
            case .moved(let fresh):
                phase = .ready(fresh, failure: "Something changed in the Cloud workspace since this was checked. Read it again before archiving.")
            case .failed(let message):
                phase = .ready(confirmation, failure: message)
            }
        }
    }
}

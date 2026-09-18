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
    ///
    /// **There is no "checking" state any more, and that is the fix.** It had one, drawn as a
    /// spinner with Archive disabled under it, and on a machine that was asleep and not waking the
    /// sheet stayed there for ever: the one dialog somebody opens BECAUSE the machine is
    /// unreachable was the one that needed it to answer. Archiving is runbloom.app's work and needs
    /// no machine, so the sheet opens on what runbloom.app already knows, with Archive live, and
    /// the machine's own answer only ever improves the sentence.
    private enum Phase {
        case ready(CloudArchiveConfirmation, failure: String? = nil)
        case archiving(CloudArchiveConfirmation)

        var confirmation: CloudArchiveConfirmation {
            switch self {
            case .ready(let confirmation, _), .archiving(let confirmation): confirmation
            }
        }

        var isArchiving: Bool {
            if case .archiving = self { true } else { false }
        }
    }

    /// Whether the machine has been asked yet, and what came of it. The first is a quiet line
    /// rather than a spinner, and none of the three changes what the buttons do.
    private enum Ask {
        case asking
        case answered
        case unanswered
    }

    @State private var phase: Phase?
    @State private var ask = Ask.asking

    private var name: String { app.cloud.item(id)?.displayName ?? "this Cloud workspace" }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            // The name as it was written, with a question mark only where the name does not end in
            // one of its own. See `CloudArchiveConfirmation.question`.
            Text(CloudArchiveConfirmation.question(archiving: name))
                .font(.headline)
            if let confirmation = phase?.confirmation {
                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    ForEach(confirmation.losses, id: \.self) { loss in
                        line(loss, glyph: loss == CloudArchiveConfirmation.conversationSentence
                             ? "bubble.left.and.exclamationmark.bubble.right" : "exclamationmark.triangle",
                             tint: Palette.warning)
                    }
                    line(CloudArchiveConfirmation.survivesSentence, glyph: "arrow.triangle.branch", tint: Palette.textSecondary)
                }
            }
            // One line, and only when there is something to say. Asking says so quietly while it
            // is happening; a machine that did not answer says that instead, and neither of them
            // takes the Archive button away.
            if ask != .answered {
                Text(ask == .asking
                     ? "Asking the machine what else would be lost…"
                     : CloudArchiveConfirmation.unaskedSentence)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .disabled(phase?.isArchiving != false)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            // What runbloom.app already knows, drawn at once: the sheet is usable before anything
            // is asked of anybody.
            phase = .ready(app.cloud.archiveConfirmationFromSummary(id))
            let asked = await app.cloud.machineArchivePreview(id)
            ask = asked == nil ? .unanswered : .answered
            // Only while the reader is still deciding. An answer that lands after Archive was
            // pressed would otherwise put the sheet back into a state it has left.
            if let asked, case .ready(_, let failure)? = phase {
                phase = .ready(asked, failure: failure)
            }
        }
    }

    private func line(_ text: String, glyph: String, tint: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: glyph).foregroundStyle(tint)
        }
    }

    private func archive() {
        guard case .ready(let confirmation, _)? = phase else { return }
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

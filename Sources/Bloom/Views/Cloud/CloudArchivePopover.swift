import BloomClient
import BloomCore
import SwiftUI

/// Confirming that a Cloud workspace is archived, which deletes its machine and its conversation.
///
/// **The local archive's popover, anchored on the row's archive box.** It was a sheet, and the
/// owner found archiving a Cloud workspace jarring beside archiving a local one: a different kind
/// of dialog, in a different place, which then grew. So it is `ConfirmationPopover`, the shell
/// `ArchiveConfirmationPopover` is, at the same width, with the same title, the same two buttons
/// and the same keys, raised from the same place on the row.
///
/// **It never changes size once it is open.** The sheet grew twice: it opened with nothing under
/// the name, then the losses runbloom.app knew arrived, then the machine's own list replaced them,
/// longer, and the line saying it was asking became a two-line sentence or went away. Here every
/// part that can change has a slot of fixed height from the first frame: the losses sit in a
/// region sized for the machine's longest usual answer, scrolling past that, and the status line
/// always reserves two lines. What changes inside a slot cross-fades. The measured sizes are
/// checked offscreen by `CloudSettingsGallery.renderArchive`.
///
/// Always asked, whatever the owner's "confirm before archiving" setting says: that setting is
/// about a local worktree, whose conversation stays in this Mac's database after it goes.
struct CloudArchivePopover: View {
    var id: CloudWorkspaceID
    var onClose: () -> Void
    @Environment(AppModel.self) private var app

    /// Where the popover is. Opened on what runbloom.app already knows, so it is usable before
    /// anything is asked of anybody: a machine that is asleep and will not wake is exactly when
    /// somebody wants out, and archiving is runbloom.app's work, which needs no machine.
    @State private var confirmation: CloudArchiveConfirmation?
    @State private var status = CloudArchivePopoverBody.Status.asking
    @State private var isArchiving = false

    var body: some View {
        CloudArchivePopoverBody(
            name: app.cloud.item(id)?.displayName ?? "this Bloom Cloud workspace",
            confirmation: confirmation ?? app.cloud.archiveConfirmationFromSummary(id),
            status: status,
            isArchiving: isArchiving,
            onConfirm: archive,
            onCancel: onClose
        )
        .task(id: id) {
            let asked = await app.cloud.machineArchivePreview(id)
            // Only while the reader is still deciding. An answer that lands after Archive was
            // pressed would otherwise change what is being archived under them.
            guard !isArchiving else { return }
            if let asked { confirmation = asked }
            if case .failed = status { return }
            status = asked == nil ? .unanswered : .answered
        }
    }

    private func archive() {
        let confirmed = confirmation ?? app.cloud.archiveConfirmationFromSummary(id)
        isArchiving = true
        Task {
            switch await app.cloud.archive(id, confirmed: confirmed) {
            case .archived:
                onClose()
            case .moved(let fresh):
                confirmation = fresh
                status = .failed("Something changed in the Bloom Cloud workspace since this was checked. Read it again before archiving.")
                isArchiving = false
            case .failed(let message):
                status = .failed(message)
                isArchiving = false
            }
        }
    }
}

/// What the popover draws, as a value, so the gallery can draw every state of it and measure that
/// they are the same size.
struct CloudArchivePopoverBody: View {
    enum Status: Equatable {
        case asking
        case answered
        case unanswered
        case failed(String)
    }

    var name: String
    var confirmation: CloudArchiveConfirmation
    var status: Status
    var isArchiving: Bool
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room for the conversation sentence, three more losses and the line about what survives,
    /// which covers all but the machine's longest answers. A longer list scrolls inside the region
    /// rather than growing the popover, and the last line it can show is faded off rather than cut,
    /// so a clipped row reads as more to scroll instead of as a bug.
    static let lossesHeight: CGFloat = 152

    /// Two lines of the caption, as a height rather than as a reserved line count: `lineLimit(2,
    /// reservesSpace: true)` alone left the unanswered sentence a point taller than the other two,
    /// which the probe caught and which is exactly the kind of growth this popover exists to stop.
    static let statusHeight: CGFloat = 30

    var body: some View {
        ConfirmationPopover(
            title: "Archive this Bloom Cloud workspace?",
            confirmLabel: isArchiving ? "Archiving…" : "Archive",
            tint: confirmation.isDestructive ? Palette.negative : Palette.controlAccent,
            canConfirm: !isArchiving,
            onConfirm: onConfirm,
            onCancel: onCancel,
            width: 380
        ) {
            // A name is not a word and does not go in the title: see the local archive dialog.
            // Known when the popover opens, so it cannot move anything later.
            Text(name)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    ForEach(confirmation.losses, id: \.self) { loss in
                        line(loss, glyph: loss == CloudArchiveConfirmation.conversationSentence
                             ? "bubble.left.and.exclamationmark.bubble.right" : "exclamationmark.triangle",
                             tint: Palette.warning)
                    }
                    line(CloudArchiveConfirmation.survivesSentence, glyph: "arrow.triangle.branch", tint: Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(confirmation)
                .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: Self.lossesHeight)
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }

            Text(statusText)
                .font(Typo.caption)
                .foregroundStyle(statusIsFailure ? Palette.negative : Palette.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: Self.statusHeight, maxHeight: Self.statusHeight, alignment: .topLeading)
                .id(statusText)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: confirmation)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: status)
    }

    private var statusText: String {
        switch status {
        case .asking: "Asking the machine what else would be lost…"
        case .answered: "Checked with the machine just now."
        case .unanswered: CloudArchiveConfirmation.unaskedSentence
        case .failed(let message): message
        }
    }

    private var statusIsFailure: Bool {
        if case .failed = status { true } else { false }
    }

    private func line(_ text: String, glyph: String, tint: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: glyph).foregroundStyle(tint)
        }
    }
}

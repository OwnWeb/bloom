import BloomClient
import BloomCore
import SwiftUI

/// Confirming that a Cloud workspace is deleted, which removes its machine and its conversation.
///
/// It stays anchored to the control that asked, but its height follows the content. The previous
/// fixed loss and status slots left a large empty middle while clipping the two sentences that
/// mattered. Every sentence now wraps in the ordinary reading order, with freshness directly
/// after the consequences and the surviving branch directly after that. `CloudArchiveProbe`
/// checks the compact and constrained forms offscreen.
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
            // Only while the reader is still deciding. An answer that lands after Delete was
            // pressed would otherwise change what is being deleted under them.
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
                status = .failed("Something changed in the Bloom Cloud workspace since this was checked. Read the updated details before deleting.")
                isArchiving = false
            case .failed(let message):
                status = .failed(message)
                isArchiving = false
            }
        }
    }
}

/// What the popover draws, as a value, so the offscreen probe can exercise every state.
struct CloudArchivePopoverBody: View {
    static let title = "Delete this Bloom Cloud workspace?"

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
    var width: CGFloat = 380
#if DEBUG
    var onFocusChange: ((String?) -> Void)?
#endif

    @FocusState private var focus: Field?

    private enum Field: Hashable { case cancel, confirm }

    /// The sequence is not a description beside the view. `body` renders these elements in order,
    /// so the probe pins the same source that determines VoiceOver's traversal.
    var semanticReadingOrder: [String] {
        presentationElements.flatMap(\.spoken)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentationElements) { element in
                row(element).padding(.top, element.spacingBefore)
            }
        }
        // Hierarchical .primary otherwise resolves through the selected row's white foreground.
        .environment(\.backgroundProminence, .standard)
        .environment(\.isOnEmphasizedSelection, false)
        .foregroundStyle(Palette.textPrimary)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: width)
        .defaultFocus($focus, .cancel)
        .task {
            // Dynamic rows can miss SwiftUI's first default-focus evaluation. Wait until that
            // pass is over, then choose the safe answer only if nothing, including a quick user
            // action, has already taken focus.
            await Task.yield()
            guard !Task.isCancelled, focus == nil else { return }
            focus = .cancel
        }
#if DEBUG
        .onChange(of: focus, initial: true) { _, value in
            onFocusChange?(value.map { $0 == .cancel ? "Cancel" : "Delete" })
        }
#endif
    }

    private var presentationElements: [PresentationElement] {
        var elements: [PresentationElement] = [
            .title(Self.title),
            .name(name),
        ]
        elements += confirmation.losses.enumerated().map { index, loss in
            .consequence(index: index, text: loss, isPrimary: loss == CloudArchiveConfirmation.conversationSentence)
        }
        elements += [
            .freshness(statusText, isFailure: statusIsFailure),
            .survives(CloudArchiveConfirmation.survivesSentence),
            .actions(confirmLabel: isArchiving ? "Deleting…" : "Delete"),
        ]
        return elements
    }

    @ViewBuilder
    private func row(_ element: PresentationElement) -> some View {
        switch element {
        case .title(let text):
            Text(text)
                .font(.headline)
                .accessibilityIdentifier("confirmation-title")
        case .name(let text):
            // A name is not a word and does not go in the title: see the local archive dialog.
            Text(text)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloud-delete-name")
        case .consequence(let index, let text, let isPrimary):
            line(
                text,
                glyph: isPrimary ? "trash" : "exclamationmark.triangle",
                tint: Palette.negative,
                identifier: "cloud-delete-consequence-\(index)"
            )
        case .freshness(let text, let isFailure):
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(isFailure ? Palette.negative : Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloud-delete-status")
        case .survives(let text):
            line(
                text,
                glyph: "arrow.triangle.branch",
                tint: Palette.textSecondary,
                identifier: "cloud-delete-survives"
            )
        case .actions(let confirmLabel):
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("confirmation-cancel")
                Button(confirmLabel, role: .destructive) {
                    guard !isArchiving else { return }
                    onConfirm()
                }
                .buttonStyle(.bordered)
                .tint(Palette.negative)
                .foregroundStyle(Palette.negative)
                .focused($focus, equals: .confirm)
                .disabled(isArchiving)
                .accessibilityIdentifier("confirmation-confirm")
            }
        }
    }

    private var statusText: String {
        switch status {
        case .asking: "Checking the machine for current work…"
        case .answered: "Verified with the machine just now."
        case .unanswered: CloudArchiveConfirmation.unaskedSentence
        case .failed(let message): message
        }
    }

    private var statusIsFailure: Bool {
        if case .failed = status { true } else { false }
    }

    private func line(_ text: String, glyph: String, tint: Color, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private enum PresentationElement: Identifiable {
        case title(String)
        case name(String)
        case consequence(index: Int, text: String, isPrimary: Bool)
        case freshness(String, isFailure: Bool)
        case survives(String)
        case actions(confirmLabel: String)

        var id: String {
            switch self {
            case .title: "title"
            case .name: "name"
            case .consequence(let index, _, _): "consequence-\(index)"
            case .freshness: "freshness"
            case .survives: "survives"
            case .actions: "actions"
            }
        }

        var spoken: [String] {
            switch self {
            case .title(let text), .name(let text), .freshness(let text, _), .survives(let text): [text]
            case .consequence(_, let text, _): [text]
            case .actions(let confirmLabel): ["Cancel", confirmLabel]
            }
        }

        var spacingBefore: CGFloat {
            switch self {
            case .title: 0
            case .freshness: Metrics.spacing
            case .actions: 16
            case .name, .consequence, .survives: 12
            }
        }
    }
}

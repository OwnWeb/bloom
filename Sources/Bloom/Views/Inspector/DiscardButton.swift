import SwiftUI

/// The Discard control, on a file's bar and on a hunk's band.
///
/// **Quiet until the pointer is on it.** It sits beside `ViewedToggle` in the same accessory bar
/// style and the same small size, and a `role: .destructive` button in that style is red at rest:
/// a row of forty files in the review would carry forty red words, and the one control nobody
/// should press by habit would be the loudest thing in every header. So the ink is the row's own
/// until hover, and the red arrives with the pointer, which is when the press is about to happen.
///
/// A disabled one keeps its reason in the tooltip, because "why can I not press this" is the only
/// question a greyed control raises.
struct DiscardButton: View {
    var title = "Discard"
    var help: String
    var disabledReason: String?
    /// Small in a bar, as `ViewedToggle` is. A hunk's band is one code row tall and takes `.mini`.
    var size: ControlSize = .small
    /// The ink at rest: the bar's own, or the gutter's on a band among code rows.
    var ink: Color?
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.uturn.backward")
        }
        .foregroundStyle(restingOrHovered)
        .buttonStyle(.accessoryBar)
        .controlSize(size)
        .disabled(disabledReason != nil)
        .onHover { isHovered = $0 }
        .help(disabledReason ?? help)
        .accessibilityHint(disabledReason ?? help)
    }

    private var restingOrHovered: AnyShapeStyle {
        if isHovered, disabledReason == nil { return AnyShapeStyle(Palette.negative) }
        return ink.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary)
    }
}

extension View {
    /// The confirmation for a Discard, as a popover on the control that asked.
    ///
    /// It was a `confirmationDialog`, which on macOS is a sheet dropped over the middle of the
    /// window: the diff the reader was deciding about went grey behind it, and a question about one
    /// hunk sat nowhere near that hunk. The archive confirmation in the sidebar is already a
    /// popover on its own button, through the same `ConfirmationPopover`, so this is that shape
    /// rather than a second one. Cancel has focus and Return never confirms, which that view
    /// enforces for every confirmation that uses it.
    ///
    /// `message` is a closure, read only while the popover is being built. The file's version asks
    /// the edit session whether there are unsaved edits, which must not happen in a `body`: see
    /// `UnsavedEditsDot`.
    func discardConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        message: @escaping () -> String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: .bottom) {
            ConfirmationPopover(
                title: title,
                confirmLabel: "Discard",
                tint: Palette.negative,
                onConfirm: {
                    isPresented.wrappedValue = false
                    onConfirm()
                },
                onCancel: { isPresented.wrappedValue = false }
            ) {
                Text(message())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// `discardConfirmation` as a value, for a bar that attaches the same question in more than one
/// place and would rather build it once.
struct DiscardConfirmationModifier: ViewModifier {
    var isPresented: Binding<Bool>
    var title: String
    var message: () -> String
    var onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.discardConfirmation(
            isPresented: isPresented, title: title, message: message, onConfirm: onConfirm
        )
    }
}

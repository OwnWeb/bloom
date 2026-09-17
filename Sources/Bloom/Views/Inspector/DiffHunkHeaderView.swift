import SwiftUI
import BloomCore

/// The `@@` line, showing the enclosing function git found. Quiet, because it is orientation
/// rather than content.
///
/// The glyph is the enclosing scope, which is what the line says whenever git can name one. It
/// used to be a left-and-right arrow, which on a band directly above a diff that really does
/// scroll sideways read as a scrolling hint.
///
/// Which hunks get one at all is `DiffHunkHeading`, not this view: only the ones the reader
/// reaches after lines the pane did not print, or every hunk when the band carries the hunk's
/// Discard.
///
/// **The Discard sits at the trailing edge in the band's own ink**, the same `DiscardButton` the
/// file's bar uses, so it goes red under the pointer and nowhere else. A diff of forty hunks is
/// forty of these, and a band is a line of orientation first.
struct DiffHunkHeaderView: View {
    var text: String
    var width: CGFloat
    var path = ""
    private var filename: String { (path as NSString).lastPathComponent }
    var discard: HunkDiscard.Availability = .hidden
    /// The hunk the band is over, for the confirmation's sentence.
    var hunk: DiffHunk?
    /// Whether this band's confirmation is open. Held by `DiffView` rather than here, so a poll
    /// rebuilding the rows cannot close a question somebody is reading.
    var isConfirming: Binding<Bool> = .constant(false)
    var onDiscard: () -> Void = {}

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "curlybraces")
                .font(Typo.micro)
                .imageScale(.small)
                // Decoration: the scope is in the text beside it, and every comparable glyph down
                // this column is already hidden.
                .accessibilityHidden(true)
            Text(text)
                .font(Font(CodeMetrics.numberFont))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            discardButton
        }
        .foregroundStyle(Palette.codeGutter)
        .padding(.horizontal, CodeMetrics.textInset)
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
        .background(Palette.codeBackground)
    }

    @ViewBuilder
    private var discardButton: some View {
        let control = FileBarControls.discardHunk(filename: filename)
        switch discard {
        case .hidden:
            EmptyView()
        case .enabled:
            button(control, reason: nil)
        case let .disabled(reason):
            button(control, reason: reason)
        }
    }

    private func button(_ control: FileBarControl, reason: String?) -> some View {
        // `.mini`, because a code row is shorter than the accessory bar's small control and this
        // band must not be taller than every line around it.
        DiscardButton(
            title: control.title, help: control.hint, disabledReason: reason,
            size: .mini, ink: Palette.codeGutter, action: { isConfirming.wrappedValue = true }
        )
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .discardConfirmation(
            isPresented: isConfirming,
            title: HunkDiscard.question(path: path),
            message: { hunk.map(HunkDiscard.losses(of:)) ?? "" },
            onConfirm: onDiscard
        )
    }
}

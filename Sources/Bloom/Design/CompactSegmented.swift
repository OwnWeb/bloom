import SwiftUI

/// A segmented picker sized for a strip of small controls rather than for a form.
///
/// The same four modifiers closed five pickers, on Home's strip, the file bar and the file
/// preview (whose bar set the size once for all its controls), and each of them is load bearing. `.labelsHidden()` because the title is for VoiceOver
/// and the segments already say what they are. `.controlSize(.small)` because these sit in bars
/// the height of `Metrics.barHeight`, where a regular segmented control fills the bar edge to edge.
/// `.fixedSize()` because a segmented control does not truncate: offered less than it needs, it
/// overflows and is clipped, which is how a segment ends up half visible at the edge of a narrow
/// pane. Fixed at its ideal size, it is the neighbours that give way instead.
///
/// It works on a `Group` of two pickers as well as on one, which `FileHeaderBar.layoutPicker`
/// relies on: a modifier on a `Group` is applied to whichever branch inside it is drawn.
extension View {
    func compactSegmented() -> some View {
        pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
    }
}

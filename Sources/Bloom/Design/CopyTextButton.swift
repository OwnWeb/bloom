import SwiftUI

/// A worded copy button: "Copy address" until it is pressed, "Copied" for
/// `Clipboard.flashDuration`, and dead while it says so.
///
/// Its own view rather than a mode of `CopyButton`, for the reason that file gives about the
/// titled button in Settings: that one is a glyph that swaps for a tick, this one is a word that
/// swaps for another word, and the two share nothing but `CopyFlash`.
///
/// It exists because `PostcardOffer` and `CommandLineOffer` each wrote the same six lines and the
/// same `@State`, word for word, under a comment saying they followed the pattern the others had
/// agreed on. Disabled while flashing is part of that pattern rather than decoration: it is what
/// keeps a second press from restarting a timer under the first one's label.
struct CopyTextButton: View {
    /// What the button says at rest, in the caller's words.
    var title: String
    /// What lands on the pasteboard.
    var text: String

    @State private var flash = CopyFlash()

    var body: some View {
        Button(flash.isShowing ? "Copied" : title) { flash.copy(text) }
            .disabled(flash.isShowing)
            .onDisappear { flash.cancel() }
    }
}

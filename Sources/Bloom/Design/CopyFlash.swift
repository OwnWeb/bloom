import SwiftUI

/// The "Copied" moment after a press: text onto the pasteboard, a flag that says so for
/// `Clipboard.flashDuration`, and the task that takes the flag down again.
///
/// Five controls wrote this out for themselves, and they had drifted. Two restarted the timer on a
/// second press and cancelled it when they went away, two did neither and relied on being disabled
/// while flashing, and the welcome window keyed the flag to a row and never cancelled its timer at
/// all. What they agree on is written down once here:
///
/// - The reset task is cancelled and restarted on every flash, so a second copy inside the window
///   does not have the first one's timer clear the label out from under it a moment later.
/// - `cancel()` is for `.onDisappear`, so nothing outlives the control that started it.
/// - A key says which of several things was copied, for a view that draws one button per row and
///   holds one of these for all of them. A caller with one button never names one.
///
/// One object held in `@State` rather than a flag and a task beside it in every caller, because the
/// two travel together: a caller holding the flag and forgetting the timer is how the drift above
/// happened. In `@State`, it lives exactly as long as the view that draws it.
@MainActor
@Observable
final class CopyFlash {
    /// What was copied last, while the flash is up. Nil once it has gone.
    private var shown: AnyHashable?
    @ObservationIgnored private var reset: Task<Void, Never>?

    /// The key a caller with a single button copies under, so it never has to invent one.
    private static let whole = AnyHashable("whole")

    /// Whether anything is flashing, which for a single button is whether it is.
    var isShowing: Bool { shown != nil }

    /// Whether the flash that is up belongs to `key`.
    func isShowing(_ key: AnyHashable) -> Bool { shown == key }

    /// Puts `text` on the pasteboard and raises the flash.
    func copy(_ text: String, for key: AnyHashable? = nil) {
        Clipboard.copy(text)
        flash(key ?? Self.whole)
    }

    /// For a caller whose text has to be fetched first, such as a patch read out of git.
    ///
    /// Nothing is copied and nothing flashes when the fetch comes back empty: a tick over an empty
    /// pasteboard is a control saying it did something it did not do. The fetch itself is left to
    /// finish if the control goes away, as it always was; only the timer is tied to the view.
    func copy(for key: AnyHashable? = nil, text: @escaping @MainActor () async -> String?) {
        Task {
            guard let text = await text(), !text.isEmpty else { return }
            copy(text, for: key)
        }
    }

    /// Takes the timer down, for `.onDisappear`. The flag is left as it is, because the view that
    /// would draw it is going away.
    func cancel() {
        reset?.cancel()
        reset = nil
    }

    private func flash(_ key: AnyHashable) {
        shown = key
        reset?.cancel()
        reset = Task { [weak self] in
            try? await Task.sleep(for: Clipboard.flashDuration)
            guard !Task.isCancelled else { return }
            self?.shown = nil
        }
    }
}

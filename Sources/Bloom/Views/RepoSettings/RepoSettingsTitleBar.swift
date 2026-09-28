import AppKit
import SwiftUI
import BloomCore

/// Gives the project settings window an ordinary Mac title bar.
///
/// The title is never lost, only undrawn: `navigationTitle` sets `NSWindow.title` whatever else
/// is on the window, so making it visible again is all this has to do about it. That matters
/// because the window has to say which project it belongs to, and the sidebar inside it says only
/// which part of that project is showing.
///
/// The folder comes along as the window's `representedURL`, so the title bar behaves like every
/// document window on the Mac: the proxy icon beside the title drags into a terminal or an editor,
/// and Command-clicking the title drops down the path from the project up to the volume, each
/// level of which opens in Finder.
///
/// It also refuses the system's window tabbing, which is the one thing on this window that nobody
/// asked for. macOS groups windows of the same class into one tabbed window by default, so opening
/// settings for a second project merged it into the first as a tab, and a `+` beside it offered a
/// third. This window is one project's, and it already has a list of its own saying which part of
/// that project is showing: a row across the top meaning "which project" above a list meaning
/// "which part of this project" reads as neither. There is nothing to gain here from the system's
/// row either, since the window's own four panes are what a settings window is for.
/// `.disallowed` is per window rather than `NSWindow.allowsAutomaticWindowTabbing = false`, which
/// would be the app speaking for windows this file knows nothing about.
///
/// AppKit rather than SwiftUI because SwiftUI models neither of the two things this needs. Nothing
/// in SwiftUI un-hides a title the framework decided to hide, and there is no scene modifier for
/// tabbing at all. `WindowChrome` reaches for the main window's title bar the same way and for the
/// same reason.
struct RepoSettingsTitleBar: ViewModifier {
    let repo: Repo

    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            // Both halves can arrive first: the window is attached a pass after the view exists,
            // and a project renamed in the main window changes the folder under an open window.
            .onChange(of: window, initial: true) { _, _ in apply() }
            .onChange(of: repo.path) { _, _ in apply() }
    }

    private func apply() {
        guard let window else { return }
        // The title itself stays `navigationTitle`'s to set, so there is one place that decides
        // what this window is called.
        window.titleVisibility = .visible
        window.representedURL = URL(filePath: repo.path)
        window.tabbingMode = .disallowed
        // Refusing tabbing decides what may happen to this window next, not what has already
        // happened to it: a window that is in a group when the mode is set stays in it, measured.
        // Nothing merges a window before this runs in practice, because the mode is set as the
        // window is attached and the second window is what merges. A pair restored from saved
        // state is the case that could, and it would look exactly like the fix having failed.
        if let group = window.tabGroup, group.windows.count > 1 {
            group.removeWindow(window)
        }
    }
}

extension View {
    /// Titles the project settings window after the project, and points it at its folder.
    func showsProjectInTitleBar(_ repo: Repo) -> some View {
        modifier(RepoSettingsTitleBar(repo: repo))
    }
}

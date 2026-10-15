import Foundation
import BloomCore

/// What a browser session can ask the window around it for.
///
/// A `BrowserSession` owns a web view and knows where the page is. It does not know which
/// workspace it belongs to, which tab it is, or how the centre column is arranged, and it must not
/// learn: the session outlives every view that draws it and is reached from a shared store, so a
/// reference to a `WorkspaceModel` held here would keep one alive for as long as the tab exists
/// and would be wrong the first time a tab moved.
///
/// So the two things a page can make happen outside its own pane are closures, handed down by the
/// pane that is drawing the session, on every update rather than once. That is the same shape and
/// the same reason as `BrowserWebView.paneMenu`: a tab can be dragged into another pane, and what
/// a pane can do belongs to the pane.
///
/// Both default to doing nothing, which is what a session drawn by nobody should do. `MenuProbe`
/// builds one of these sessions with no pane at all around it.
@MainActor
struct BrowserPaneHost {
    /// Open a browser tab on this address, in front. `BrowserTab.openWindow` is the one door.
    var openTab: (URL) -> Void = { _ in }
    /// Open a browser tab for the 1Password extension and hand back its session, because the
    /// extension reads the tab it asked for straight away and throws on nil. Wider than `openTab`
    /// by the extension's own pages only. See `BrowserPasswordManager.mayOpenTab`.
    var openExtensionTab: (URL) -> BrowserSession? = { _ in nil }
    /// Close this tab, for the 1Password extension's `tabs.remove`. False when no pane is drawing
    /// the session, which leaves nothing that knows which tab it is.
    var closeTab: () -> Bool = { false }
    /// Tell the reader something Bloom decided on their behalf. There is one of these so far, and
    /// it is a page being refused more windows than `BrowserPopups` allows.
    var report: (BrowserPopups.Notice) -> Void = { _ in }
}

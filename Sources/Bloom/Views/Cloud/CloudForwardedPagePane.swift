import AppKit
import BloomCore
import SwiftUI

/// A port of a Cloud workspace forwarded to this Mac, open in a pane of the window.
///
/// **An ordinary page at an ordinary address, in the local browser.** The forward has already done
/// the hard part: `localhost:<port>` on this Mac is the workspace's dev server, so there is no
/// exchange to make and no token to hide, and the pane is `BrowserTabView`'s bar and page without
/// the parts that need a worktree on this Mac. See `BrowserToolbar.Surface.forwardedPage`.
///
/// **A forward ends when Bloom quits**, and a tab can outlive it by being restored. So the pane
/// checks the address against what `CloudPorts` is forwarding now, and says so over the page when
/// nothing is, rather than leaving WebKit to report a refused connection in its own words.
struct CloudForwardedPagePane: View {
    var session: CloudWorkspaceSession
    var tab: CenterTab
    /// The pane's own menu, under the page's, as `CloudPreviewPane` takes it: without it a right
    /// click offers only WebKit's items and a page that never loaded leaves no way to close the pane.
    var paneMenu: (@MainActor () -> NSMenu)?

    @State private var address = ""
    @FocusState private var isAddressFocused: Bool
    @State private var isCapturing = false
    @Environment(AppModel.self) private var app

    private var browser: BrowserSession { CenterTabStore.shared.browser(for: tab) }

    /// Whether this Mac is forwarding the port the tab was opened on.
    private var isForwarded: Bool {
        guard let local = WorkspacePorts.forwardedLocalPort(in: tab.url) else { return false }
        return session.ports.rows.contains { $0.localPort == local }
    }

    var body: some View {
        let browser = browser
        VStack(spacing: 0) {
            BrowserToolbarView(
                toolbar: BrowserToolbar(
                    surface: .forwardedPage,
                    page: browser.page,
                    canGoBack: browser.canGoBack,
                    canGoForward: browser.canGoForward,
                    isLoading: browser.isLoading,
                    loadProgress: browser.loadProgress,
                    isCapturing: isCapturing
                ),
                address: $address,
                addressFocus: $isAddressFocused,
                isRingVisible: isAddressFocused,
                backHistory: browser.backHistory,
                forwardHistory: browser.forwardHistory,
                goBack: browser.goBack,
                goForward: browser.goForward,
                goToHistory: { browser.go(back: $0) },
                reloadOrStop: {
                    if browser.isLoading { browser.webView.stopLoading() } else { browser.reload() }
                },
                capture: { capture(browser) },
                viewport: Binding(get: { browser.viewport }, set: { browser.viewport = $0 }),
                submit: {
                    browser.load(address)
                    isAddressFocused = false
                }
            )
            ZStack {
                BrowserViewportView(session: browser, paneMenu: paneMenu)
                if !isForwarded {
                    EmptyStateView(
                        glyph: "arrow.left.arrow.right",
                        title: "This port is not forwarded now",
                        message: "Forwards end when you stop them or quit Bloom. Forward it again from Ports in the toolbar, then reload."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.surface)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: tab.id) {
            address = browser.displayAddress
            CenterTabStore.shared.setPage(browser.page, for: tab)
        }
        .onChange(of: browser.page) {
            if !isAddressFocused { address = browser.displayAddress }
            CenterTabStore.shared.setPage(browser.page, for: tab)
        }
    }

    private func capture(_ browser: BrowserSession) {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            if let alert = await session.attachSnapshot(of: browser) { app.alert = alert }
        }
    }
}

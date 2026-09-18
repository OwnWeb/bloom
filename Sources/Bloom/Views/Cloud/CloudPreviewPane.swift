import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// A Cloud workspace's own app, in a pane of the window rather than in another application.
///
/// **A window onto one machine, and deliberately not a browser.** The owner's first prompt in a
/// Cloud workspace was "show me the homepage in a pane next to this chat", and until now the only
/// answer was a button that opened his real browser. What a local workspace has in the same place
/// is a browser tab, which is a place to type an address; this cannot be that, because what it
/// draws is reached through a token that is single use and lasts a minute. An address bar over a
/// one-time token is a promise the thing cannot keep, so there is none: this shows the machine's
/// app and offers to reload it.
///
/// **Every showing is a fresh exchange.** `GET /_bloom/preview/enter?token=` sets the preview
/// cookie for that machine's host and redirects to the app; the token behind it cannot be used
/// twice. So opening, reloading and coming back after a relaunch each ask runbloom.app for a new
/// one rather than replaying the address, which is what makes the restore case work by
/// construction: there is no stored address to have gone stale.
///
/// The address is checked before it is loaded, by the same rule `openPreview` checks it with: the
/// machine's own host, over HTTPS, at the exchange path. runbloom.app naming another host would be
/// the one way this pane could be pointed somewhere it should not go.
struct CloudPreviewPane: View {
    var session: CloudWorkspaceSession

    /// The page itself, made on the first exchange and kept for the life of the pane, so a reload
    /// is a reload rather than a new web view with a new cookie store.
    @State private var browser: BrowserSession?
    @State private var problem: String?
    @State private var isOpening = true

    var body: some View {
        VStack(spacing: 0) {
            bar
            Hairline()
            content
        }
        .task { await open() }
    }

    @ViewBuilder
    private var content: some View {
        if let problem {
            EmptyStateView(
                glyph: "exclamationmark.triangle",
                title: "Could not open the preview",
                message: problem,
                actionTitle: "Try again",
                action: { Task { await open() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let browser {
            BrowserWebViewHost(session: browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isOpening {
            LoadingView("Opening the preview")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What a browser tab's address bar stands in for: which machine this is, and the two things
    /// worth doing to it. No field, for the reason at the head of this file.
    private var bar: some View {
        HStack(spacing: Metrics.spacingWide) {
            Image(systemName: PaneGlyph.browser)
                .foregroundStyle(Palette.textTertiary)
            Text(host)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Reload", systemImage: "arrow.clockwise") { Task { await open() } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Ask the Cloud workspace for its app again")
            Button("Open in Browser", systemImage: "arrow.up.forward.app") {
                Task { await session.openPreview() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Open this in your browser")
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: InspectorLayout.barHeight)
    }

    /// The machine's host while there is one, and the workspace's name before the first exchange
    /// has answered. Never an address somebody could mistake for something to type into.
    private var host: String {
        browser?.currentURL?.host() ?? session.surfaceName
    }

    private func open() async {
        isOpening = true
        problem = nil
        defer { isOpening = false }
        switch await session.previewEntry() {
        case .address(let url):
            if let browser {
                browser.load(url.absoluteString)
            } else {
                browser = BrowserSession(url: url.absoluteString)
            }
        case .refused(let sentence):
            problem = sentence
        }
    }
}

/// One exchange address, or the sentence saying why there is none. Its own type rather than a
/// `Result`, because the failure is a sentence to draw rather than an error to throw: there is
/// nobody above this to catch one.
enum PreviewEntry {
    case address(URL)
    case refused(String)
}

/// The page, hosted for a pane that has no browser tab behind it.
///
/// `BrowserTabView` is the local browser's whole apparatus: an address bar, downloads, a find bar,
/// snapshots into a worktree and region capture. None of that belongs to a window onto a machine,
/// and half of it needs a worktree, so this pane takes the web view and leaves the rest.
private struct BrowserWebViewHost: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> BrowserHostView {
        let host = BrowserHostView()
        host.attach(session.pageView)
        return host
    }

    func updateNSView(_ host: BrowserHostView, context: Context) {
        host.attach(session.pageView)
    }
}

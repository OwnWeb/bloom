import AppKit
import BloomClient
import BloomCore
import BloomProtocol
import SwiftUI

/// A Cloud workspace's own app, in a pane of the window rather than in another application.
///
/// **The same browser as a local workspace's, with fewer controls.** It was a browser of its own
/// for a day: a thin custom row with a glyph, a host and two borderless buttons, on the argument
/// that a pane reached through a one-time token is not a place to type an address. The owner put it
/// beside the local browser and said it plainly, that it does not look the same. The argument was
/// right and the conclusion was wrong: what cannot work here is a control, not a way of dressing a
/// pane. So this draws `BrowserToolbarView`, the local browser's own bar, and `BrowserToolbar.Surface`
/// holds the three things a machine has less of and the reason for each.
///
/// **Every showing is a fresh exchange.** `GET /_bloom/preview/enter?token=` sets the preview
/// cookie for that machine's host and redirects to the app; the token behind it cannot be used
/// twice. So opening, reloading and coming back after a relaunch each ask runbloom.app for a new
/// one rather than replaying the address, which is what makes the restore case work by
/// construction: there is no stored address to have gone stale. Reload and Open in Default Browser
/// both go through that exchange rather than through the address on screen.
///
/// The address is checked before it is loaded, by the same rule `openPreview` checks it with: the
/// machine's own host, over HTTPS, at the exchange path. runbloom.app naming another host would be
/// the one way this pane could be pointed somewhere it should not go.
///
/// **What it says when there is no app to show is `CloudPreviewReadiness`**, which is a sentence
/// naming the state rather than a spinner. A white rectangle under a bar is what a page that failed
/// looks like, and a workspace whose setup has not run will never fill it in on its own.
struct CloudPreviewPane: View {
    var session: CloudWorkspaceSession
    /// The pane's own menu, merged under the page's. Without it a right click on the page offers
    /// only WebKit's Reload and Inspect Element, and a pane whose page has not loaded yet is
    /// nothing but page, so there was no way to close it. See `BrowserPageWebView`.
    var paneMenu: (@MainActor () -> NSMenu)?

    /// The page itself, made on the first exchange and kept for the life of the pane, so a reload
    /// is a reload rather than a new web view with a new cookie store.
    @State private var browser: BrowserSession?
    /// Why runbloom.app would not hand over an address, which is a different failure from anything
    /// the page can report. Nil unless the last exchange was refused.
    @State private var refusal: CloudPreviewReadiness.Notice?
    @State private var isOpening = false
    /// A screenshot already on its way to the composer, so the camera goes quiet rather than
    /// attaching the same page twice. The local pane keeps the same flag for the same reason.
    @State private var isCapturing = false
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
        }
        .task { await openIfReady() }
        // Setup finishing is what makes "the page appears here on its own" true. The pane is
        // holding a sentence rather than a request at that moment, so nothing else would notice.
        .onChange(of: session.state.setup?.state) { _, _ in
            Task { await openIfReady() }
        }
        // And the connection going live is the other. Nothing is fetched before it: see
        // `openIfReady`.
        .onChange(of: session.phase) { _, _ in
            Task { await openIfReady() }
        }
    }

    // MARK: - The bar

    private var toolbar: some View {
        BrowserToolbarView(
            toolbar: BrowserToolbar(
                surface: .machineApp,
                page: browser?.page ?? BrowserTabTitle.BrowserPage(),
                canGoBack: browser?.canGoBack ?? false,
                canGoForward: browser?.canGoForward ?? false,
                isLoading: browser?.isLoading ?? isOpening,
                loadProgress: browser?.loadProgress ?? 0,
                isCapturing: isCapturing
            ),
            address: .constant(shownAddress),
            isRingVisible: false,
            backHistory: browser?.backHistory ?? [],
            forwardHistory: browser?.forwardHistory ?? [],
            goBack: { browser?.goBack() },
            goForward: { browser?.goForward() },
            goToHistory: { step in browser?.go(back: step) },
            reloadOrStop: { Task { await openIfReady() } },
            openInBrowser: { Task { await session.openPreview() } },
            capture: capture,
            viewport: Binding(
                get: { browser?.viewport ?? BrowserViewport() },
                set: { browser?.viewport = $0 }
            )
        )
    }

    /// Where the page is, without the token it was reached with, and the machine's host before the
    /// first exchange has answered. See `BrowserToolbar.Surface.shownAddress`.
    private var shownAddress: String {
        BrowserToolbar.Surface.machineApp.shownAddress(browser?.page.address ?? "")
    }

    // MARK: - The page, or the reason there is none

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let browser {
                // The local browser's own page host, which is what makes the viewport control in
                // the bar do something: it holds the sizing, the scroll view around an oversized
                // page and the border round it. A plain web view in a frame would have left that
                // button drawn and dead.
                BrowserViewportView(session: browser, paneMenu: paneMenu)
            }
            // Over the web view rather than instead of it, as in `BrowserTabView`: the page keeps
            // its identity, so a workspace that starts serving does not load into a pane that has
            // just been rebuilt.
            if let notice {
                EmptyStateView(
                    glyph: "exclamationmark.triangle",
                    title: notice.title,
                    message: notice.message,
                    actionTitle: notice.invitesRetry ? (session.phase == .live ? "Try again" : "Wake") : nil,
                    action: notice.invitesRetry ? {
                        // Somebody asking for the app on a sleeping workspace IS the wake. The load
                        // follows by itself when the connection goes live.
                        if session.phase != .live { session.wake() }
                        Task { await openIfReady() }
                    } : nil
                )
                .background(Palette.surface)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What is wrong, in the order the reader can act on it.
    ///
    /// Setup first, because a workspace that has not set up cannot be serving whatever the page
    /// says; then a refusal, which is runbloom.app declining to hand over an address at all; then
    /// the page's own failure, which has a sentence written against the error it got; and last the
    /// gateway answering for a port nobody is listening on, which is the white rectangle this was
    /// written for.
    private var notice: CloudPreviewReadiness.Notice? {
        if session.phase != .live { return asleepNotice }
        if case .waiting(let waiting) = CloudPreviewReadiness.of(setup: session.state.setup) {
            return waiting
        }
        if let refusal { return refusal }
        guard let browser else { return nil }
        if let failure = browser.failure {
            return CloudPreviewReadiness.Notice(
                title: failure.title, message: failure.message, invitesRetry: true
            )
        }
        if CloudPreviewReadiness.isSilent(status: browser.pageStatus) {
            // The machine's own account first, because for up to five minutes after setup says it
            // succeeded the machine is starting the app and the sentence below tells the reader to
            // go and do it themselves. See `CloudPreviewReadiness.starting(services:)`.
            return CloudPreviewReadiness.starting(services: session.state.workspace?.services ?? [])
                ?? CloudPreviewReadiness.nothingAnswered
        }
        return nil
    }

    // MARK: - A picture of the app, into the conversation beside it

    /// The same screenshot the local browser's camera takes, into the same composer.
    ///
    /// **The bytes never touch a worktree on either kind of workspace, which is why this works at
    /// all.** `ComposerHandoff` writes them where the workspace says attachments go, which for a
    /// Cloud chat is the staging directory, and the turn uploads them to the machine when it goes.
    /// So the picture of an app running on a machine is sent to the agent on that machine, and
    /// nothing about the road it takes is particular to this pane.
    private func capture() {
        guard !isCapturing, let browser else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            let data: Data
            do {
                data = try await browser.snapshot()
            } catch {
                app.alert = BloomAlert(
                    title: "That page could not be captured", message: error.readableMessage
                )
                return
            }
            // Named after the page, avoiding what the chat is already carrying, exactly as the
            // local pane names its own.
            let taken = Set(
                PromptAttachmentStore.shared
                    .attachments(for: (session.activeChat?.id ?? session.chats.first?.id)?.rawValue ?? "")
                    .map(\.filename)
            )
            let name = BrowserSnapshot.filename(for: browser.displayAddress, avoiding: taken)
            let outcome = await ComposerHandoff.attach(
                [.image(data, format: .png, named: name)], to: session
            )
            guard let failure = outcome.failure else { return }
            app.alert = BloomAlert(title: "That screenshot was not attached", message: failure)
        }
    }

    /// The page the agent asked for, once the exchange has let this pane in.
    ///
    /// **Two loads rather than one, because the exchange decides where the first one lands.**
    /// `preview/enter` sets the cookie for the machine's host and redirects to the app's front
    /// page; it takes no destination of its own. So a request for `/orders` is that exchange
    /// followed by an ordinary navigation, which the cookie now allows. The reader sees the front
    /// page for the moment in between, which is the honest picture of what happened.
    ///
    /// The wait is a ceiling on infinity rather than a measurement: a load that never finishes
    /// leaves the pane on the front page, which is where it would have been anyway, and no version
    /// of this should sit here for longer than somebody would watch.
    private func goToRequestedPage(host: String?) async {
        guard let destination = session.tookPreviewDestination(), let host, let browser else { return }
        let deadline = Date().addingTimeInterval(15)
        while browser.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !browser.isLoading else { return }
        browser.load("https://" + host + destination)
    }

    /// What the pane says while the workspace is not connected, which is short because the column's
    /// own banner above it is already saying the rest.
    ///
    /// **A machine that is asleep is woken by being asked**, and this pane's load is a request to
    /// the machine, so drawing it while the connection is down is this app deciding on somebody's
    /// behalf to wake a machine and start the clock on it. It waits to be asked instead.
    private var asleepNotice: CloudPreviewReadiness.Notice {
        switch session.phase {
        case .asleep, .notWaking:
            CloudPreviewReadiness.Notice(
                title: "This Bloom Cloud workspace is asleep",
                message: "Its app is not running while it sleeps. Waking it starts it again.",
                invitesRetry: true
            )
        default:
            CloudPreviewReadiness.Notice(
                title: "Not connected yet",
                message: "The app appears here once Bloom has connected to this workspace.",
                invitesRetry: false
            )
        }
    }

    /// Asks for an address and loads it, unless setup says there is nothing to load yet.
    ///
    /// Nothing is fetched while setup is going: the exchange would succeed, the gateway would
    /// answer for a port nobody holds, and the pane would have spent a token to learn what the
    /// setup record already said.
    private func openIfReady() async {
        // Nothing is asked of a machine that is not connected. The exchange is a request to it, and
        // a request is what wakes a sleeping machine: see `asleepNotice`.
        guard session.phase == .live else { return }
        guard case .serving = CloudPreviewReadiness.of(setup: session.state.setup) else { return }
        isOpening = true
        refusal = nil
        defer { isOpening = false }
        switch await session.previewEntry() {
        case .address(let url):
            if let browser {
                browser.load(url.absoluteString)
            } else {
                browser = BrowserSession(url: url.absoluteString)
            }
            await goToRequestedPage(host: url.host())
        case .refused(let sentence):
            refusal = CloudPreviewReadiness.Notice(
                title: "Could not open the preview", message: sentence, invitesRetry: true
            )
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

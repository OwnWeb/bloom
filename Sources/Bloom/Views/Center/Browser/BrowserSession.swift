import AppKit
import Foundation
import Observation
import WebKit
import BloomCore

/// One browser tab's live web view, and everything the address bar needs to know about it.
///
/// The view is owned here for the same reason a shell is owned by `TerminalSessionStore`: SwiftUI
/// rebuilds views whenever anything near them changes, and a rebuilt `WKWebView` is a page that
/// reloads itself, forgets its history and throws away the form you were halfway through.
///
/// It is an ordinary web view and nothing more. There is no scheme handler, and a page loaded here
/// has exactly the reach any page in Safari would have: none at all into this app, its database,
/// its worktrees or the user's credentials.
///
/// The one message handler is the console listener, and it is added only when an agent first
/// calls `browser_console`. What a page can do with it is post lines into a capped log that
/// reaches a model marked as untrusted, which is no more than the page could already say in its
/// own text. See `BrowserSession+Agent`.
///
/// The one addition is 1Password's Safari extension, when it is switched on in Settings: it runs
/// in these pages as it would in Safari, and its own pages are kept from every `browser_` tool.
/// See `BrowserExtensionHost` and `BrowserPasswordManager.agentRefusal`.
@MainActor
@Observable
final class BrowserSession {
    /// The page. A `var` for one reason: a tab showing one of 1Password's own pages has to be
    /// given a new web view once the extension loads, because WebKit takes a web view's
    /// configuration when it is made and never again. See `adoptExtension(configuration:)`.
    @ObservationIgnored private(set) var webView: BrowserPageWebView

    /// What a pane actually puts on screen, which is not the web view itself.
    ///
    /// The Web Inspector attaches by adding its own view to the web view's SUPERVIEW and shrinking
    /// the web view to make room for it. Handing the web view straight to the pane, which is what
    /// this did first, meant that superview was the host SwiftUI had just made, so switching
    /// workspace or splitting the pane left the inspector behind in a host that was then thrown
    /// away: the page sprang back to full size, the inspector was gone from the window, and WebKit
    /// still reported it as open. A wrapper of this session's own is a superview that travels with
    /// the web view, so the two move between panes together.
    let pageView = BrowserHostView()

    var viewport = BrowserViewport()

    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var isPageScrolled = false
    private(set) var scrollEdgeImage: NSImage?
    @ObservationIgnored private var scrollEdgeCapture: Task<Void, Never>?
    @ObservationIgnored private var scrollEdgeNeedsCapture = false
    /// How far the fetch in flight has got, rounded to hundredths.
    ///
    /// Rounded because WebKit reports this continuously and every write redraws the pane. A
    /// hundredth is under four points of the field the fill is drawn in, so nothing is lost and
    /// the number of redraws a load can cost is capped at a hundred.
    private(set) var loadProgress: Double = 0
    /// Where the page actually is, which is not what the user has typed into the address field.
    private(set) var currentURL: URL?
    /// Why the last navigation failed, or nil when nothing has. Cleared the moment a document
    /// commits, because a failed load leaves the previous page in place and the reader is then
    /// looking at something real again. See `BrowserLoadFailure`.
    private(set) var failure: BrowserLoadFailure?
    private(set) var pageStatus: Int?
    /// Where the page is and what it says it is called, as one value.
    ///
    /// The pair rather than two properties, because the strip has to be told about both in one
    /// go: a title and the navigation that brought it arrive in the same update, and a view with
    /// an `onChange` for each has no way to say which runs first. See
    /// `BrowserTabTitle.advance`.
    ///
    /// The title here is never cleared. WebKit sets `title` to nil the moment a new document
    /// commits and fills it in a beat later, so mirroring the property exactly would empty this
    /// between every two pages; holding the last one is what lets the strip keep a name up while
    /// the next page loads. Whether it is still true of where the tab has got to is decided in
    /// `BrowserTabTitle`, against the address beside it.
    private(set) var page = BrowserTabTitle.BrowserPage()

    @ObservationIgnored private let navigation = NavigationObserver()
    @ObservationIgnored private let ui = BrowserUIObserver()
    @ObservationIgnored private let scrollObserver = BrowserScrollObserver()

    /// What this pane can ask the window around it for, which the session cannot do itself. Set by
    /// the pane drawing it, on every update. See `BrowserPaneHost`.
    ///
    /// `@ObservationIgnored` because it is assigned from inside SwiftUI's own update pass: a
    /// tracked write from there invalidates the view that is mid update, which is the recursion
    /// `AppModel.model(for:)` documents at length.
    @ObservationIgnored var host = BrowserPaneHost()

    /// How many windows the page in this session may open, and what happens when it asks for more.
    /// The rule is in the core; this is the count for this one page.
    @ObservationIgnored private var popups = BrowserPopups()

    /// How the page's own questions are put up, and how many it may ask. The rule is in the core;
    /// this is the count for this one page, and it is reset by a document committing.
    @ObservationIgnored private var dialogs = BrowserDialogs()
    @ObservationIgnored private let dialogPresenter = BrowserDialogPresenter()

    /// How many files a page may hand over, which is `BrowserDownloads` in the core.
    @ObservationIgnored private var downloadLimit = BrowserDownloads()

    /// What this page has handed over, newest last, for the strip under the toolbar. It is also
    /// what holds each download's delegate alive, since `WKDownload.delegate` is weak.
    private(set) var downloads: [BrowserDownloadItem] = []

    /// What the page has logged since an agent first asked. Internal rather than private because
    /// `BrowserSession+Agent` is its writer. See `BrowserConsoleLog`.
    @ObservationIgnored var consoleLog = BrowserConsoleLog()

    /// Find in Page: whether the bar is up, what is in it and how the last search went. The rules
    /// are `BrowserFind` in the core.
    private(set) var find = BrowserFind()

    /// The question in flight about this page's icon, so a tab that navigates twice does not leave
    /// two of them racing to file an answer against two different origins.
    @ObservationIgnored private var iconRequest: Task<Void, Never>?

    /// This tab as 1Password's extension sees it, or nil when the extension was off as the web view
    /// was made, which is the only moment WebKit lets one be attached. See `BrowserExtensionHost`.
    @ObservationIgnored private(set) var extensionTab: BrowserExtensionTab?

    /// The extension's toolbar button, which its popup hangs from. Set by the button as it is
    /// drawn, weak because the pane owns it.
    @ObservationIgnored weak var extensionAnchor: NSView?

    /// How many times this tab has arrived on one of 1Password's own pages. Only ever moves up, so
    /// a bridge call that reads it before and after knows whether the tab went to one in between,
    /// even if it has left again. See `BrowserPasswordManager.agentRefusal`.
    @ObservationIgnored private(set) var protectedPageArrivals = 0

    /// Whether the web view was made with the extension's configuration, which is the only kind
    /// that can show 1Password's own pages and the one kind that cannot leave them. See
    /// `BrowserPasswordManager.crossing`.
    @ObservationIgnored private var showsExtensionPages = false

    /// Set by `stop`. A closed tab can still be reached by the extension's waiting list or by a
    /// navigation decision that was in flight as it closed, and either would otherwise give it a
    /// new web view and report it to 1Password as an open tab again.
    @ObservationIgnored private var isStopped = false

    /// KVO on everything the toolbar reads, because the navigation delegate does not see every
    /// navigation.
    ///
    /// It started as KVO on `title` alone, since there is no delegate callback for a title:
    /// `didFinish` fires before the title of a page that sets it from script.
    ///
    /// **The address needed exactly the same treatment and did not have it, which was the bug.** A
    /// single page app navigates with `history.pushState`, which is a same document navigation:
    /// WebKit updates `url` and the back list, neither `didCommit` nor `didFinish` fires, and
    /// there is no public delegate callback for one. So the field sat on `/login` while the reader
    /// walked four pages into an Inertia site.
    ///
    /// `canGoBack` and `canGoForward` were stale in the same way and for the same reason: a
    /// `pushState` pushes a back entry without loading anything, so Back was dead on a page you
    /// really could go back from. `isLoading` is watched with them because the header documents it
    /// as KVO compliant with the rest, and `estimatedProgress` is watched for the fill behind the
    /// address.
    ///
    /// The delegate stays. It is what reports a failure, and having both is two mechanisms
    /// agreeing rather than a duplicate: `refresh` reads the web view and writes what changed.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// The worktree this tab belongs to, which is the directory a `file://` page is granted read
    /// access to. Empty for a session belonging to no workspace, which is the design gallery's,
    /// and empty is a session that will not load a local page at all. See `LocalPage.fileURL`.
    @ObservationIgnored private let root: String

    init(url: String, root: String = "") {
        self.root = root
        Self.preferInspectorDocked()
        // One of 1Password's own pages needs the extension's configuration rather than a fresh
        // one, or WebKit refuses to serve it. See `BrowserExtensionHost.configuration(forPageAt:)`.
        let extensionConfiguration = BrowserExtensionHost.shared.configuration(forPageAt: url)
        let configuration = extensionConfiguration ?? WKWebViewConfiguration()
        let usesExtensions = BrowserExtensionHost.shared.attach(to: configuration)
        webView = Self.makeWebView(configuration, scrollObserver: scrollObserver)
        showsExtensionPages = extensionConfiguration != nil
        navigation.owner = self
        scrollObserver.owner = self
        ui.owner = self
        install(webView)
        // Shown in the address field from the first frame, before anything has been fetched.
        currentURL = BrowserAddress.url(from: url)
        page = BrowserTabTitle.BrowserPage(address: displayAddress)
        if usesExtensions {
            let tab = BrowserExtensionTab(session: self)
            extensionTab = tab
            BrowserExtensionHost.shared.didOpen(tab)
        }
        if extensionConfiguration == nil, let address = currentURL,
           BrowserPasswordManager.isExtensionPage(address) {
            waitForExtension()
        } else {
            load(url)
        }
    }

    /// A web view on `configuration`, set up the way every browser tab is. Shared by `init` and by
    /// the swap in `adoptExtension(configuration:)`.
    ///
    /// The scroll observer is added to the configuration's own content controller, which WebKit
    /// throws on if the name is already taken there. A browser tab's configuration is made fresh
    /// for it, and one of 1Password's pages is handed a copy of the extension's, which was
    /// measured to come with a content controller of its own, so neither can collide.
    private static func makeWebView(
        _ configuration: WKWebViewConfiguration, scrollObserver: BrowserScrollObserver
    ) -> BrowserPageWebView {
        enableDeveloperExtras(on: configuration.preferences)
        configuration.userContentController.add(
            scrollObserver, contentWorld: .defaultClient, name: BrowserScrollObserver.handlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserScrollObserver.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .defaultClient
            )
        )
        let view = BrowserPageWebView(frame: .zero, configuration: configuration)
        keepPageFromTakingKeyboard(view)
        view.allowsBackForwardNavigationGestures = true
        // A dev server is the whole point of this tab, and one that is still booting answers with
        // a connection refused rather than with a page. Painting the app's own surface behind the
        // page keeps that moment from flashing white in a dark window.
        view.underPageBackgroundColor = NSColor(Palette.surface)
        return view
    }

    /// Wires a web view to this session and puts it on screen. Shared by `init` and by the swap
    /// in `adoptExtension(configuration:)`, so a replaced page is wired exactly as the first one.
    private func install(_ view: BrowserPageWebView) {
        pageView.attach(view)
        view.navigationDelegate = navigation
        view.uiDelegate = ui
        // Weak, because the web view is owned by this session: a strong capture here would be the
        // session holding itself through its own subview.
        view.findCommand = { [weak self] command in self?.perform(command) }
        view.wasShown = { [weak self] in self?.becomeActiveTab() }
        observations = [
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                // On the main thread, measured rather than assumed: WebKit posts every one of
                // these from there, which is also the only thread its properties may be read on.
                MainActor.assumeIsolated {
                    self?.adopt(BrowserTabTitle.BrowserPage(title: view.title ?? ""))
                }
            },
            // No `.initial` on these, unlike the title: the lines at the end of the initialiser
            // set the same facts from the address the tab is opening on, and an initial
            // notification would land before them and read an empty web view.
            view.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            view.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            view.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            view.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            view.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
    }

    // MARK: - 1Password's own pages

    /// One of 1Password's own pages that this tab cannot show yet, because the extension serving
    /// it is not loaded. The tab says so, and the host hands it the extension's configuration the
    /// moment there is one. Nothing is loaded meanwhile: loading it now would only be the -1008
    /// blank page again, on a web view that can never recover from it.
    @ObservationIgnored private var awaitsExtension = false

    private func waitForExtension() {
        awaitsExtension = true
        showWaiting(BrowserExtensionHost.shared.waitingPage)
        BrowserExtensionHost.shared.waitForExtension(self)
    }

    /// What the tab says while it waits, which the host sends again every time the extension's
    /// status moves, so it never goes on promising something that has stopped being true.
    func showWaiting(_ page: BrowserLoadFailure?) {
        guard awaitsExtension, let page else { return }
        if failure != page { failure = page }
    }

    /// The extension is being unloaded. A tab on one of its pages is left on a configuration that
    /// serves nothing, so it stops and waits, and answers whether it did. The host puts it on the
    /// waiting list itself and says what it shows, because this is called from inside `stop`.
    func pauseForExtension() -> Bool {
        guard let address = currentURL, BrowserPasswordManager.isExtensionPage(address) else {
            return false
        }
        webView.stopLoading()
        awaitsExtension = true
        return true
    }

    /// The extension has loaded, and this tab was waiting for it. The web view is replaced by one
    /// made with the extension's configuration, and the page this tab was on is loaded into it.
    ///
    /// **The tab is registered with the extension afresh, around the new web view.** Its old
    /// registration, if it had one, was made while it held the old web view, and a tab restored
    /// with the switch off had none at all, which left the page loaded with no 1Password button
    /// and invisible to `tabs.query`.
    func adoptExtension(configuration: WKWebViewConfiguration) {
        guard !isStopped, awaitsExtension, let address = currentURL else { return }
        awaitsExtension = false
        replaceWebView(configuration: configuration, showsExtensionPages: true)
        failure = nil
        load(address.absoluteString)
    }

    /// Onto one of 1Password's own pages from an ordinary web view, which cannot show it. Asked for
    /// by the address bar or by the extension's own `tabs.update`, never by a page. See
    /// `BrowserPasswordManager.crossing`.
    ///
    /// The history the tab had stays with the web view it had, because WebKit gives no way to hand
    /// a back list from one web view to another.
    private func enterExtensionPages(at url: URL) {
        // Counted here, because `currentURL` is moved below and `refresh` will then see no change.
        protectedPageArrivals += 1
        webView.stopLoading()
        currentURL = url
        page = BrowserTabTitle.BrowserPage(address: displayAddress)
        guard let configuration = BrowserExtensionHost.shared.configuration(forPageAt: url.absoluteString) else {
            waitForExtension()
            return
        }
        replaceWebView(configuration: configuration, showsExtensionPages: true)
        failure = nil
        webView.load(URLRequest(url: url))
    }

    /// Out to the web from one of 1Password's own pages, whose web view will not go. This is
    /// 1Password's Sign in, which sends its welcome page to `start.1password.com`.
    func leaveExtensionPages(for url: URL) {
        guard !isStopped else { return }
        replaceWebView(configuration: WKWebViewConfiguration(), showsExtensionPages: false)
        failure = nil
        webView.load(URLRequest(url: url))
    }

    /// Puts a new web view made with `configuration` where the old one was, wired the same way.
    ///
    /// **The tab is registered with the extension afresh, around the new web view.** Its old
    /// registration, if it had one, was made while it held the old web view, and a tab restored
    /// with the switch off had none at all, which left the page loaded with no 1Password button
    /// and invisible to `tabs.query`.
    private func replaceWebView(configuration: WKWebViewConfiguration, showsExtensionPages: Bool) {
        let host = BrowserExtensionHost.shared
        if let extensionTab {
            host.didClose(extensionTab)
            self.extensionTab = nil
        }
        let usesExtensions = host.attach(to: configuration)
        let listening = consoleLog.isListening
        stopListeningToConsole()
        consoleLog.isListening = false
        let old = webView
        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        let view = Self.makeWebView(configuration, scrollObserver: scrollObserver)
        view.paneMenu = old.paneMenu
        view.underPageBackgroundColor = old.underPageBackgroundColor
        webView = view
        self.showsExtensionPages = showsExtensionPages
        install(view)
        if usesExtensions {
            let tab = BrowserExtensionTab(session: self)
            extensionTab = tab
            host.didOpen(tab)
        }
        if listening { listenToConsole() }
        if view.window != nil { becomeActiveTab() }
    }

    /// Whether a navigation the page itself started has to leave for an ordinary web view. Asked
    /// by the navigation delegate, which cancels it and calls `leaveExtensionPages`.
    fileprivate func mustLeaveExtensionPages(for url: URL) -> Bool {
        BrowserPasswordManager.crossing(
            to: url, showsExtensionPages: showsExtensionPages, requestedByPage: true
        ) == .outOfExtension
    }

    /// The reader put this tab on screen or clicked in it, so it is the one 1Password fills. A
    /// navigation does not count, because a dev server reloading a tab in another pane is not the
    /// reader turning to it. See `BrowserExtensionHost.activate`.
    func becomeActiveTab() {
        guard let extensionTab else { return }
        BrowserExtensionHost.shared.activate(extensionTab)
    }

    func setPageScrollOffset(_ offset: Double) {
        guard offset > 0 else {
            isPageScrolled = false
            scrollEdgeImage = nil
            scrollEdgeNeedsCapture = false
            return
        }
        isPageScrolled = true
        captureScrollEdge()
    }

    /// WebKit does not expose a live material surface for a toolbar outside its view. A narrow
    /// snapshot gives the bar the colours passing immediately below it without moving the page
    /// behind the controls and hiding the page's first line at rest.
    func captureScrollEdge() {
        guard isPageScrolled, webView.window != nil,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        guard scrollEdgeCapture == nil else {
            scrollEdgeNeedsCapture = true
            return
        }
        scrollEdgeCapture = Task { [weak self] in
            guard let self else { return }
            repeat {
                scrollEdgeNeedsCapture = false
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(
                    x: 0, y: 0, width: webView.bounds.width,
                    height: min(Metrics.barHeight, webView.bounds.height)
                )
                if let image = try? await webView.takeSnapshot(configuration: configuration),
                   isPageScrolled {
                    scrollEdgeImage = image
                }
            } while scrollEdgeNeedsCapture && isPageScrolled
            scrollEdgeCapture = nil
        }
    }

    /// Points the tab at whatever the user typed. Anything that cannot be read as an address is
    /// ignored rather than handed to a search engine: this field is for the dev server next door,
    /// and shipping a half-typed line off to a third party is not what it is for.
    func load(_ text: String) {
        // A tab waiting for 1Password can be sent somewhere else, which ends the wait, but not
        // back to one of 1Password's pages, which is the load that cannot work yet.
        if awaitsExtension {
            if let url = BrowserAddress.url(from: text), BrowserPasswordManager.isExtensionPage(url) {
                return
            }
            awaitsExtension = false
        }
        // A page out of the worktree, which cannot go the way every other address goes. WebKit
        // drops a `file://` handed to it as a `URLRequest` and leaves the pane blank, and a page
        // loaded with read access to itself alone comes out unstyled, because the stylesheet
        // beside it is a separate origin it may not fetch. `loadFileURL` with the worktree root is
        // the supported answer to both, and `LocalPage.fileURL` is what refuses an address
        // pointing outside that root before the root is handed over.
        if let file = LocalPage.fileURL(from: text, root: root) {
            // A web view made for 1Password's pages will not load anything else. See `crossing`.
            if showsExtensionPages {
                replaceWebView(configuration: WKWebViewConfiguration(), showsExtensionPages: false)
            }
            webView.loadFileURL(
                file, allowingReadAccessTo: URL(filePath: root, directoryHint: .isDirectory)
            )
            return
        }
        guard let url = BrowserAddress.url(from: text) else { return }
        switch BrowserPasswordManager.crossing(
            to: url, showsExtensionPages: showsExtensionPages, requestedByPage: false
        ) {
        case .stay: webView.load(URLRequest(url: url))
        case .intoExtension: enterExtensionPages(at: url)
        case .outOfExtension: leaveExtensionPages(for: url)
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// The pages behind this one, nearest first, as the menu under the Back arrow draws them.
    ///
    /// Read off `WKBackForwardList` on demand rather than mirrored into a property: the list is
    /// not observable, so a stored copy would need a writer on every navigation and would be one
    /// more thing to get out of step with the web view. Every navigation already moves `page` or
    /// `isLoading`, both of which are observed, so the toolbar is rebuilt and asks again.
    var backHistory: [BrowserToolbar.HistoryEntry] {
        BrowserToolbar.backMenu(webView.backForwardList.backList.map(Self.page))
    }

    var forwardHistory: [BrowserToolbar.HistoryEntry] {
        BrowserToolbar.forwardMenu(webView.backForwardList.forwardList.map(Self.page))
    }

    /// Somewhere further back or further forward than one step. The distance is
    /// `BrowserToolbar.HistoryEntry.id`, which is WebKit's own index into this list.
    func go(back distance: Int) {
        guard let item = webView.backForwardList.item(at: distance) else { return }
        webView.go(to: item)
    }

    private static func page(_ item: WKBackForwardListItem) -> BrowserTabTitle.BrowserPage {
        BrowserTabTitle.BrowserPage(address: item.url.absoluteString, title: item.title ?? "")
    }

    func reload() {
        // Nothing to reload until the extension serving this page is back. See `awaitsExtension`.
        guard !awaitsExtension else { return }
        // A reader pressing reload is asking for this page again, icon included. It is the only
        // way to get a second look at an origin that had no icon the first time, which a dev
        // server that has since grown one is exactly. See `BrowserFaviconStore.claim`.
        if let origin = BrowserFavicon.origin(of: displayAddress) {
            BrowserFaviconStore.shared.forget(origin)
        }
        // A dev server that was not up when the tab opened has no page to reload, so an empty
        // view reloads the address instead of reloading nothing.
        if webView.url == nil, let url = currentURL {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    /// A picture of the page as it is on screen right now, as PNG.
    ///
    /// **The visible viewport, not the whole page.** `takeSnapshot` with no rect captures what is
    /// in the pane, which is the thing the user is pointing at when they press the button: the
    /// complaint this feature exists for is "this button is misaligned, look", and what makes that
    /// legible is that the picture is what they were looking at, scroll position and all. Capturing
    /// the full page is possible, by giving `snapshotWidth` the document height, and it is worse in
    /// every case that matters here. A page with a sticky header renders it once, halfway down. A
    /// list that virtualises its rows captures the twenty rows that exist. And an infinite scroller
    /// produces a forty megabyte image of a loading spinner. A viewport shot is always exactly what
    /// was on screen, which is the only promise a screenshot button can keep.
    ///
    /// `afterScreenUpdates` is left at its default of true, so a page that has just been scrolled
    /// or has just finished laying out is captured as it settled rather than a frame before.
    ///
    /// PNG rather than the `NSImage` WebKit hands back, because the attachment path takes bytes
    /// and a format, and because PNG is what a screenshot on this machine already is.
    /// `width`, in points, is for the one caller that is not a person: `browser_screenshot` asks
    /// for `BrowserSnapshot.agentWidth` rather than the pane's own, because that picture is paid
    /// for by the token instead of being looked at. Nil is the pane's width and is what the camera
    /// button passes, so what the reader gets is unchanged.
    func snapshot(width: Double? = nil) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        // Points, not pixels, so the picture comes out at the retina size the pane is drawn at
        // rather than at half of it. Nil would give the same, but only while the default holds.
        configuration.snapshotWidth = NSNumber(value: width ?? Double(webView.bounds.width))

        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            throw BrowserSnapshotFailure()
        }
        return png
    }

    /// The rendered text of the page, for `browser_text`.
    ///
    /// Trimmed of the blank lines a laid-out page produces at either end, and nothing else: what
    /// comes back is what the reader can see, and editing it further would be Bloom deciding which
    /// of somebody else's words matter. The envelope it travels in is `BridgeUntrustedText`, and
    /// the cap is `BrowserPageText`.
    func text() async throws -> String {
        let value = try await evaluate(.visibleText) { $0 as? String }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Moves the page, and answers with where it ended up: how far down, how tall the page is, and
    /// how much of it the pane is showing.
    ///
    /// The three come back out of the page, so they are read as integers and nothing else. A
    /// number that has been through `Int` carries nothing a page wrote, which is what makes them
    /// safe to put in a sentence a model reads. See `BrowserScroll.report`.
    func scroll(_ scroll: BrowserScroll) async throws -> (offset: Int, height: Int, viewport: Int) {
        try await evaluate(.scroll(scroll)) { value in
            guard let numbers = value as? [Double], numbers.count == 3 else { return nil }
            return (Int(numbers[0]), Int(numbers[1]), Int(numbers[2]))
        }
    }

    /// Runs one of Bloom's own scripts in the page.
    ///
    /// **The parameter is a `BrowserPageScript` and never a `String`, and that signature is the
    /// safety property rather than a nicety.** There is no method on this type that evaluates text
    /// a caller supplied, so there is no expression anywhere in the app that can put a bridge
    /// caller's characters into this page. The head of `BrowserPageScript` says what the scripts
    /// are, and the head of `BrowserPaneCommand` argues why Bloom offers no tool that would want
    /// an arbitrary one.
    ///
    /// The completion-handler form rather than the `async` overload, which looks tidier and is a
    /// trap: WebKit's async spelling returns a non-optional `Any`, so a script evaluating to
    /// `undefined` crashes in the thunk before the value reaches the caller. A page that has just
    /// navigated is exactly when that happens.
    ///
    /// `read` runs inside the completion handler rather than after it, and that is not a style
    /// choice either: `Any` is not `Sendable`, so resuming a continuation with the raw value is a
    /// data race the compiler refuses. Turning it into a `String` or three `Int`s where it arrives
    /// means the only thing crossing back is a value that was safe to cross.
    private func evaluate<Value: Sendable>(
        _ script: BrowserPageScript,
        reading read: @escaping @Sendable (Any?) -> Value?
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script.source) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let read = read(value) {
                    continuation.resume(returning: read)
                } else {
                    continuation.resume(throwing: BrowserScriptFailure())
                }
            }
        }
    }

    // MARK: - The page's own icon

    /// Asks the page what its icon is, unless this origin has been asked already.
    ///
    /// Off the navigation delegate rather than off the title observation, because this is a
    /// question about a document and `didFinish` is the one callback that means one has arrived. A
    /// `pushState` inside a single page app fires none of it and needs none: the origin has not
    /// moved, so the store already holds the answer and the tab is already wearing it.
    fileprivate func findIcon() {
        guard let origin = BrowserFavicon.origin(of: displayAddress),
              BrowserFaviconStore.shared.claim(origin)
        else { return }

        iconRequest?.cancel()
        iconRequest = Task { [weak self] in await self?.findIcon(for: origin) }
    }

    /// Two questions and then silence, which is `BrowserFavicon.attempts`.
    ///
    /// **None of this costs the strip anything.** Both calls are asynchronous, the fetching and
    /// the drawing happen inside the page, and what crosses back is a few kilobytes of PNG. There
    /// is nothing here a tab being laid out can wait on, and the one write at the end lands in
    /// `BrowserFaviconStore`, which the strip reads from a dictionary.
    private func findIcon(for origin: String) async {
        for delay in BrowserFavicon.attempts {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            // The page moved off this origin while Bloom was waiting, so any answer now would be
            // filed against a site the tab has left.
            guard BrowserFavicon.origin(of: displayAddress) == origin else { return }

            let links = await iconLinks()
            // Nothing declared yet. A framework that writes its `<link rel=icon>` from script has
            // not necessarily written it by the time the page finishes loading, which is the whole
            // reason there is a second attempt.
            guard let choice = BrowserFavicon.choose(from: links) else { continue }

            guard let answer = await iconImage(at: choice.index),
                  // The list is read again inside the page, so a document that rewrote its
                  // `<link>` elements in between would be handing back a different icon from the
                  // one that was chosen. The same href or nothing.
                  answer.href == links[choice.index].href,
                  let png = BrowserFavicon.read(answer.dataURL)
            else { return }

            BrowserFaviconStore.shared.adopt(png, for: origin)
            return
        }
    }

    /// What the page says its icons are. See `BrowserFaviconScript`, which is where the argument
    /// about the isolated content world and the numbers passed as numbers lives.
    private func iconLinks() async -> [BrowserFaviconLink] {
        let value: Any? = try? await webView.callAsyncJavaScript(
            BrowserFaviconScript.links,
            arguments: [
                "limit": BrowserFavicon.linkLimit,
                "chars": BrowserFavicon.textLimit,
            ],
            contentWorld: .defaultClient
        )
        return BrowserFavicon.links(from: value as? [String] ?? [])
    }

    /// One of them, named by its place in that list rather than by its address, drawn into a square
    /// the page is told the size of and handed back as a PNG.
    private func iconImage(at index: Int) async -> (href: String, dataURL: String)? {
        let value: Any? = try? await webView.callAsyncJavaScript(
            BrowserFaviconScript.image,
            arguments: [
                "index": index,
                "size": BrowserFavicon.pixels,
                "chars": BrowserFavicon.textLimit,
                "timeout": BrowserFavicon.loadTimeout,
            ],
            contentWorld: .defaultClient
        )
        guard let pair = value as? [String], pair.count == 2 else { return nil }
        return (href: pair[0], dataURL: pair[1])
    }

    /// The page asked for a window of its own, through `target="_blank"` or `window.open`.
    ///
    /// The whole decision is `BrowserPopups` in the core, so this is the wiring and nothing else:
    /// a tab in front, silence, or one sentence to the reader. See `BrowserUIObserver` for why the
    /// answer is a Bloom tab rather than a panel of WebKit's own.
    func openWindow(_ url: URL?) {
        switch popups.request(url) {
        case .open(let url):
            host.openTab(url)
        case .refuse:
            break
        case .refuseAndSay(let notice):
            host.report(notice)
        }
    }

    /// One of `alert`, `confirm` or `prompt`, asked by the page.
    ///
    /// Whether it goes up at all, what Bloom's own line above it says and how much of the page's
    /// words are drawn is `BrowserDialogs` in the core. Putting it on the window is
    /// `BrowserDialogPresenter`. What is here is the wiring, and one fact neither of those can
    /// hold: the reader ticking the box silences THIS session's page, so the answer comes back
    /// through the same call that asked.
    func ask(
        _ kind: BrowserDialogs.Kind,
        message: String,
        defaultText: String = "",
        from name: String?
    ) async -> BrowserDialogAnswer {
        switch dialogs.request(kind, message: message, defaultText: defaultText, from: name) {
        case .suppress:
            return .dismissed
        case .show(let presentation):
            let answer = await dialogPresenter.ask(kind, presentation, over: webView.window)
            if answer.isSilenced { dialogs.silence() }
            return answer
        }
    }

    /// A document committed in this pane, which is what gives a page that was silenced its voice
    /// back. Called from the navigation delegate, because a `pushState` is not one of these and
    /// must not count as one: the reader silenced a page, not an address.
    fileprivate func pageCommitted() {
        dialogs.pageCommitted()
    }

    /// Turns a navigation error into something the pane can say, or into nothing.
    ///
    /// The host is taken from the failing URL in the error rather than from `currentURL`, because
    /// a provisional navigation that never committed has not changed `currentURL` yet: reading it
    /// here would name the page the reader was on before, which is the one address the message
    /// must not blame.
    fileprivate func record(_ error: any Error) {
        let error = error as NSError
        let host = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host()
        failure = BrowserLoadFailure.of(domain: error.domain, code: error.code, host: host)
    }

    fileprivate func clearFailure() {
        if failure != nil { failure = nil }
    }

    /// The status of a main frame response, or nil at the start of a navigation that has not had
    /// one yet. Only the main frame: a page whose stylesheet 404s is a page, not a 404.
    fileprivate func record(status: Int?) {
        if pageStatus != status { pageStatus = status }
    }

    // MARK: - Find in page

    /// One of the four things the keyboard asks of Find in Page, from the Edit menu or from the
    /// key equivalents `BrowserPageWebView` claims while the page holds the keyboard.
    func perform(_ command: BrowserFindCommand) {
        switch command {
        case .show: find.show()
        case .next: step(backwards: false)
        case .previous: step(backwards: true)
        case .hide: find.hide()
        }
    }

    /// The field changed. Searched on every keystroke, which is what find does on this platform:
    /// the reader watches the page move under the words they are typing.
    func typeInFind(_ text: String) {
        find.type(text)
        step(backwards: false)
    }

    /// Looks for what is in the field, and records whether it was there.
    ///
    /// **The bar can say "Not found" and nothing else, and that is WebKit's limit rather than a
    /// decision.** `WKFindResult` carries one property, `matchFound`. There is no count and no
    /// index, and the only way to get one would be to run a script of Bloom's own over somebody
    /// else's logged-in page, which is what the head of `BrowserPaneCommand` argues at length that
    /// this pane does not do.
    ///
    /// The answer is dropped if the field has moved on while WebKit was looking, so a fast typist
    /// never sees "Not found" from two keystrokes ago.
    private func step(backwards: Bool) {
        guard find.canStep else { return find.settle(matched: false) }

        let query = find.query
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = find.isCaseSensitive
        // Round the end and on, because a find bar that stopped at the bottom of the page with no
        // count to explain why would read as having lost the match it just had.
        configuration.wraps = true

        Task { [weak self] in
            guard let self else { return }
            // A throw here is a page that went away under the search, which is a navigation
            // committing between the call and the answer. That is not a match, and it is not
            // worth a sentence either: the bar will be searched again on the next keystroke.
            let result = try? await webView.find(query, configuration: configuration)
            guard find.query == query else { return }
            find.settle(matched: result?.matchFound ?? false)
        }
    }

    // MARK: - Downloads

    /// A response became a file rather than a page. Where it goes is `BrowserDownloadItem`; how
    /// many a page may send is `BrowserDownloads` in the core.
    func begin(_ download: WKDownload) {
        switch downloadLimit.request(from: pageName) {
        case .save:
            let item = BrowserDownloadItem(download)
            downloads.append(item)
            download.delegate = item
        case .refuse:
            download.cancel { _ in }
        case .refuseAndSay(let notice):
            download.cancel { _ in }
            host.report(notice)
        }
    }

    /// Forgets the downloads the strip is drawn from. The files stay where they are: this is
    /// closing the strip, not undoing anything.
    func clearDownloads() {
        downloads.removeAll { $0.state != .running }
    }

    /// The page as `BrowserPageOrigin` names it, for the sentence a refusal carries.
    private var pageName: String? {
        guard let url = webView.url ?? currentURL, let host = url.host() else { return nil }
        return BrowserPageOrigin.name(scheme: url.scheme ?? "", host: host, port: url.port ?? 0)
    }

    func stop() {
        isStopped = true
        observations = []
        // A question put to a page whose tab has gone. Nothing would come back through it, and a
        // sleeping task holding this session is one more thing keeping a closed web view alive.
        iconRequest?.cancel()
        iconRequest = nil
        // Before the web view is let go, so a page waiting on an answer gets one. Never calling
        // WebKit's completion handler hangs that page for ever, and a closing tab must not leave a
        // sheet standing on the window either. See `BrowserDialogPresenter`.
        dialogPresenter.dismiss()
        stopListeningToConsole()
        if let extensionTab {
            BrowserExtensionHost.shared.didClose(extensionTab)
            self.extensionTab = nil
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        // With the navigation delegate, and for the same reason: a page whose pane has gone must
        // not be able to put a tab in front of the reader or a panel over the window.
        webView.uiDelegate = nil
        host = BrowserPaneHost()
        // The page view rather than the web view, so an attached inspector comes out of the window
        // with the page instead of being left in the wrapper on its own. Releasing this session
        // would get there anyway, WebKit takes an inspector down with the page it is inspecting,
        // but only once the pane drawing it has let go, and a closed tab should not still be
        // showing a console.
        pageView.removeFromSuperview()
    }

    /// What the address field should show for the page that is loaded.
    var displayAddress: String {
        currentURL?.absoluteString ?? ""
    }

    /// The page moved, or renamed itself, or both. One door for all three, and the rule is
    /// `BrowserTabTitle.advance`.
    ///
    /// **The title has to be cleared here as well as in the tab.** Measured against a real web
    /// view: loading a page with no `<title>` fires the observation with an empty string, which is
    /// no news rather than no title, so this holds the last name it had. Without the clearing that
    /// `advance` does on a change of host, a session that had been on spatie.be went on offering
    /// "Spatie" from every address after it, and the tab, which had correctly dropped the name on
    /// the navigation, was handed it straight back on the next update.
    private func adopt(_ page: BrowserTabTitle.BrowserPage) {
        let next = BrowserTabTitle.advance(from: self.page, to: page)
        guard next != self.page else { return }
        let retitled = next.title != self.page.title
        self.page = next
        if retitled { tell([.title]) }
    }

    /// Passes a change the extension can see on to it. Nothing when it is not loaded in this tab.
    private func tell(_ properties: WKWebExtension.TabChangedProperties) {
        guard let extensionTab, !properties.isEmpty else { return }
        BrowserExtensionHost.shared.changed(properties, on: extensionTab)
    }

    /// Reads the whole of the web view's state and writes back only what moved.
    ///
    /// **Only what moved, because `@Observable` does not compare.** Setting a property to the
    /// value it already holds still tells every view reading it to redraw, and one navigation
    /// calls this a dozen times over: the delegate on start, commit and finish, and KVO on each of
    /// the five properties it watches. Writing every field each time made a single page load a
    /// dozen redraws of the centre column for three actual changes.
    fileprivate func refresh() {
        var changed: WKWebExtension.TabChangedProperties = []
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
        if isLoading != webView.isLoading {
            isLoading = webView.isLoading
            changed.insert(.loading)
        }
        let progress = (webView.estimatedProgress * 100).rounded() / 100
        if loadProgress != progress { loadProgress = progress }
        // Nil is a web view that has not loaded anything rather than a page at no address, so the
        // tab keeps the address it was opened on. See `reload`, which is the other half of that.
        if let url = webView.url, url != currentURL {
            currentURL = url
            changed.insert(.URL)
            if BrowserPasswordManager.isExtensionPage(url) { protectedPageArrivals += 1 }
        }
        tell(changed)
        adopt(BrowserTabTitle.BrowserPage(address: displayAddress))
    }

    /// Puts Inspect Element in the page's own context menu, and with it the whole Web Inspector.
    ///
    /// Always on, and there is no setting: this tab exists to look at the dev server running in
    /// the worktree next door, and a dev server that will not paint is a question for the console
    /// or the network list every time. A preference would only be a way to have it switched off on
    /// the day it is wanted.
    ///
    /// **`WKWebView.isInspectable` is not the property this needs, though it reads as though it
    /// is.** It was tried first and measured to change nothing here: with it set and nothing else,
    /// a right click on the page still offers Reload and only Reload. It governs REMOTE
    /// inspection, which is the Develop menu in Safari on this Mac reaching in. The item in the
    /// page's own menu is gated on WebKit's `developerExtrasEnabled` setting, which has no public
    /// spelling, so it is reached by KVC. Measured both ways round on macOS 27: with this setting
    /// and without `isInspectable` the item is there and the inspector opens attached to the
    /// bottom of the page; with `isInspectable` and without this setting it is not.
    ///
    /// Asked before it is set, because KVC for a key that has stopped existing is an exception and
    /// not a nil, and a WebKit that renamed this should cost the tab one menu item rather than
    /// take the app down as the pane opens.
    private static func enableDeveloperExtras(on preferences: WKPreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) else {
            return
        }
        preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    /// Page `focus()`, which every agent click and fill triggers, made WebKit take the window's
    /// keyboard from the composer. Refusing in `becomeFirstResponder` is too late: the composer
    /// has already resigned. Private setting, reached by KVC as in `enableDeveloperExtras`.
    private static func keepPageFromTakingKeyboard(_ webView: WKWebView) {
        guard webView.responds(to: NSSelectorFromString("_setShouldSuppressFirstResponderChanges:"))
        else { return }
        webView.setValue(true, forKey: "shouldSuppressFirstResponderChanges")
    }

    /// The key WebKit remembers the inspector's last attachment in, and it is WebKit's own: it
    /// writes it into whichever application's defaults the inspected web view belongs to.
    private static let startsAttachedKey =
        "__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached"

    /// Asks for the inspector docked into the pane rather than floating in a window of its own.
    ///
    /// The first version of this shipped believing the inspector opened docked, because in every
    /// harness it was measured in it did. It does not always: WebKit refuses to dock into a view
    /// smaller than 500 points wide, or shorter than 334, and silently opens a window instead.
    /// Bisected on macOS 27: 500 wide docks and 499 does not, 334 tall docks and 333 does not,
    /// which is WebKit's 500 point minimum width and its rule that a docked inspector may take
    /// three quarters of the height and must have 250 points. A browser tab that is one half of a
    /// split centre column is easily under the first of those, which is where the floating window
    /// came from.
    ///
    /// **And WebKit then remembers it.** A detach writes the key above, and so does an open that
    /// was forced to detach because the pane was too small, so one look at the inspector in a
    /// narrow pane makes every later one float, at any size, for good. That is why this writes the
    /// preference rather than reads it: the state it is correcting is already on disk.
    ///
    /// Once per launch, not once per tab, so detaching it on purpose still holds for the rest of
    /// the session. It is set before the first web view exists, because WebKit reads it when the
    /// inspector is created and caches it thereafter.
    ///
    /// There is no API for this. `WKPreferences` has nothing about attachment and `_WKInspector`
    /// offers only `attach`, which is refused at these sizes exactly as opening is, and which
    /// there is no callback to call from: nothing tells the app the reader chose Inspect Element.
    /// So it is the defaults key, which is at least the one WebKit itself reads.
    private static var hasAskedForDockedInspector = false

    private static func preferInspectorDocked() {
        guard !hasAskedForDockedInspector else { return }
        hasAskedForDockedInspector = true
        UserDefaults.standard.set(true, forKey: startsAttachedKey)
    }

}

/// Kept off the session itself because `navigationDelegate` is the sort of reference that outlives
/// what it points at, and a separate object makes the weak link back explicit.
private final class NavigationObserver: NSObject, WKNavigationDelegate {
    weak var owner: BrowserSession?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // The status belongs to the document on screen, and this one is on its way out.
        owner?.record(status: nil)
        owner?.refresh()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        owner?.clearFailure()
        owner?.refresh()
        // A new document, so a page the reader had told to stop asking may ask again. This is the
        // one callback that means it: `didStartProvisionalNavigation` fires for a load that may
        // yet fail, and a failed load leaves the old document in place.
        owner?.pageCommitted()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.refresh()
        owner?.findIcon()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        owner?.record(error)
        owner?.refresh()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        // The one that matters for a mistyped address: a provisional navigation is one that never
        // got as far as a document, which is exactly what a host that does not resolve produces.
        owner?.record(error)
        owner?.refresh()
    }

    // MARK: - Turning a navigation into a file

    /// A link carrying the `download` attribute, which is a click that says "save this" rather
    /// than "show me this".
    ///
    /// **This method not existing is half of why downloads never started.** WebKit's default
    /// policy is `.allow`, and allowing a navigation that was meant to be a download leaves the
    /// page where it was with nothing said. Everything else is allowed exactly as before, so no
    /// navigation that used to happen stops happening.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // One of 1Password's pages heading for the web, which its web view would accept here and
        // then never perform. Cancelled, and done again in an ordinary web view once this
        // callback has returned, because the web view asking is the one being replaced.
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           owner?.mustLeaveExtensionPages(for: url) == true {
            Task { @MainActor [weak self] in self?.owner?.leaveExtensionPages(for: url) }
            return .cancel
        }
        return navigationAction.shouldPerformDownload ? .download : .allow
    }

    /// A response a web view cannot draw, which is the other half: a zip, a tarball, a PDF served
    /// as an attachment. Without this the response is allowed, WebKit finds it cannot render it,
    /// and the navigation quietly stops.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            owner?.record(status: http.statusCode)
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        owner?.begin(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        owner?.begin(download)
    }
}

/// The page was captured and the bytes could not be made into a PNG, which is the one failure
/// `takeSnapshot` does not report itself.
struct BrowserSnapshotFailure: LocalizedError {
    var errorDescription: String? { "Bloom could not turn this page into an image." }
}

/// One of Bloom's own scripts answered with something that is not what it returns.
///
/// The scripts are fixed and each has one shape, so this is a page that has gone away underneath
/// the call: a navigation committing between the evaluation and the answer leaves `undefined`
/// where a string or three numbers were. Its own error rather than a nil, because the tool has to
/// say something a model can act on, and "try again once it has loaded" is that sentence.
struct BrowserScriptFailure: LocalizedError {
    var errorDescription: String? {
        "That page did not answer. It may have navigated while Bloom was reading it."
    }
}

import Foundation

/// The small decisions `BrowserExtensionHost` takes on the extension's behalf. Here rather than
/// in the host because the host holds WebKit and lives in the app target, where nothing can test
/// it, and each of these has a wrong answer that would be invisible until a reader hit it.
extension BrowserPasswordManager {
    /// What the toolbar button is called. The extension's own label, or its name when it has set
    /// none, because a button with no name is one VoiceOver reads as "button".
    public static func actionLabel(_ label: String) -> String {
        label.isEmpty ? "1Password" : label
    }

    /// Which open tab a new tab the extension asked for opens beside.
    ///
    /// The active one, because that is the workspace the reader is in. Failing that the newest,
    /// because a tab must be named for the new one to land anywhere at all, and nil means the
    /// extension is told no tab could be opened rather than being handed nothing.
    public static func opener<Tab>(active: Tab?, open: [Tab]) -> Tab? {
        active ?? open.last
    }

    /// Where the extension's popup is drawn from.
    public enum PopupAnchor: Equatable, Sendable {
        /// Under the tab's toolbar button, which is where the reader pressed.
        case button
        /// From the top of the page, for a popup the extension opened by itself on a tab whose
        /// button is not on screen.
        case pageTop
        /// Nowhere, and the extension has to be told so: reporting success with nothing shown
        /// leaves it believing the popup is up.
        case nowhere
    }

    public static func popupAnchor(buttonIsInWindow: Bool, pageIsInWindow: Bool) -> PopupAnchor {
        if buttonIsInWindow { return .button }
        if pageIsInWindow { return .pageTop }
        return .nowhere
    }

    /// What a tab showing one of 1Password's own pages says while it cannot show it, because the
    /// extension that serves the page is not loaded. Nil once it is, which is the tab's cue to
    /// show the page itself.
    ///
    /// **From the status as it is now, and asked again every time the status moves.** It was set
    /// once, when the tab began to wait, so a tab went on promising that the page would open by
    /// itself after the lookup had already found 1Password missing, and went on saying it was
    /// waiting after the switch had been turned off.
    public static func waitingPage(status: Status, isOn: Bool) -> BrowserLoadFailure? {
        guard isOn else {
            return page(
                "1Password is switched off",
                "This is one of 1Password's own pages. Switch 1Password on in Settings, under "
                    + "Passwords, and it opens again by itself."
            )
        }
        switch status {
        case .off, .looking:
            return page(
                "Waiting for 1Password",
                "This is one of 1Password's own pages. It opens by itself once the extension has "
                    + "loaded."
            )
        case .notInstalled:
            return page(
                "1Password for Safari is not installed",
                "This is one of 1Password's own pages, and it needs the extension. Install "
                    + "1Password for Safari from the App Store, then switch 1Password off and on "
                    + "again in Settings, under Passwords."
            )
        case .cannotLook(let reason):
            return page(
                "Bloom could not look for 1Password",
                "macOS could not be asked which Safari extensions are installed (\(reason)). "
                    + "Switch 1Password off and on again in Settings, under Passwords."
            )
        case .failed(let reason):
            return page(
                "1Password would not load",
                "1Password for Safari was found but would not load: \(reason)"
            )
        case .ready:
            return nil
        }
    }

    private static func page(_ title: String, _ message: String) -> BrowserLoadFailure {
        BrowserLoadFailure(title: title, message: message, namesTheAddress: false)
    }
}

/// Moving a tab between 1Password's own pages and the web.
///
/// **A web view made for one of the extension's pages cannot leave them, and that was why Sign
/// in did nothing.** 1Password's welcome page signs in by setting `window.location.href` to
/// `https://start.1password.com/signin/`. WebKit asked the navigation delegate, was told yes, and
/// then never started the navigation: no provisional load, no failure, the page just stayed put.
/// Measured on macOS 27 with a test extension doing exactly that, in a web view made from
/// `WKWebExtensionContext.webViewConfiguration` the way Bloom makes one, against the same address
/// loading normally in an ordinary web view. The other direction is the -1008 the head of
/// `BrowserExtensionHost` describes. Safari moves the tab to a web view of the right kind, so this
/// says when Bloom has to do the same.
extension BrowserPasswordManager {
    public enum Crossing: Equatable, Sendable {
        /// The web view the tab has can go there itself.
        case stay
        /// Onto one of the extension's pages from an ordinary web view: a web view made with the
        /// extension's configuration has to take over.
        case intoExtension
        /// Out to the web from one of the extension's pages: an ordinary web view has to take over.
        case outOfExtension
    }

    /// What a tab has to do to go to `url`, given whether its web view was made for the extension's
    /// pages and whether the page on screen asked for the navigation rather than Bloom or the
    /// extension.
    ///
    /// **A page never gets a tab onto the extension's pages.** None of 1Password's pages are
    /// listed in its `web_accessible_resources`, so a site linking to one is refused in every
    /// browser, and swapping in a web view that could load it would be Bloom undoing that. Only
    /// the address bar and the extension's own `tabs.update` cross that way. Out to the web, only
    /// an address Bloom shows at all, which is http and https.
    public static func crossing(
        to url: URL, showsExtensionPages: Bool, requestedByPage: Bool
    ) -> Crossing {
        let isExtension = isExtensionPage(url)
        if showsExtensionPages {
            return !isExtension && BrowserAddress.shows(url) ? .outOfExtension : .stay
        }
        return isExtension && !requestedByPage ? .intoExtension : .stay
    }
}

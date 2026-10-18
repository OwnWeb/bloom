import SwiftUI
import WebKit
import BloomCore

/// A message's HTML body, drawn by WebKit from Mailpit's own preview route.
///
/// **Mailpit's `view/<id>.html` rather than the `HTML` field of the message.** The field is the
/// part as it arrived, and an image embedded in the message is a `cid:` reference in it that no web
/// view can follow. Mailpit's preview rewrites those to its part routes, so inline logos load.
///
/// **No JavaScript.** Mail clients run none, so an email that only works with it is an email that
/// is broken for its readers, and the preview should show that rather than hide it. Remote images
/// do load: this is mail the reader's own app just sent, and a template with its images stripped
/// looks broken in a way the real thing is not.
///
/// A plain click opens a link in the default browser. The link menu can also place it in Bloom's
/// most recently selected workspace. Anything that is not http or https is left alone.
struct MailBodyWebView: NSViewRepresentable {
    var url: URL
    var canOpenInBloom: Bool
    var onLink: @MainActor (URL) -> Void
    var onNewTab: @MainActor (URL) -> Void
    var onPane: @MainActor (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLink: onLink, onNewTab: onNewTab, onPane: onPane)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Nothing an email sets, a cookie or local storage, outlives the view or reaches the
        // browser tabs' own store.
        configuration.websiteDataStore = .nonPersistent()
        let view = MailPreviewWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.configureLinkMenu = { [weak coordinator = context.coordinator] menu in
            coordinator?.addLinkActions(to: menu)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        context.coordinator.onNewTab = onNewTab
        context.coordinator.onPane = onPane
        context.coordinator.canOpenInBloom = canOpenInBloom
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private enum Destination {
            case tab
            case pane
        }

        var onLink: @MainActor (URL) -> Void
        var onNewTab: @MainActor (URL) -> Void
        var onPane: @MainActor (URL) -> Void
        var canOpenInBloom = false
        var loaded: URL?
        private var pendingDestination: Destination?

        init(
            onLink: @escaping @MainActor (URL) -> Void,
            onNewTab: @escaping @MainActor (URL) -> Void,
            onPane: @escaping @MainActor (URL) -> Void
        ) {
            self.onLink = onLink
            self.onNewTab = onNewTab
            self.onPane = onPane
        }

        func addLinkActions(to menu: NSMenu) {
            pendingDestination = nil
            guard canOpenInBloom,
                  let original = menu.items.first(where: {
                      $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
                  }),
                  let index = menu.items.firstIndex(of: original) else { return }

            for (offset, title) in ["Open Link in New Tab", "Open Link in Pane"].enumerated() {
                let item = NSMenuItem(title: title, action: #selector(openInBloom(_:)), keyEquivalent: "")
                item.target = self
                item.tag = offset
                item.representedObject = original
                menu.insertItem(item, at: index + offset + 1)
            }
        }

        @objc private func openInBloom(_ sender: NSMenuItem) {
            guard let original = sender.representedObject as? NSMenuItem,
                  let action = original.action else { return }
            pendingDestination = sender.tag == 0 ? .tab : .pane
            if !NSApp.sendAction(action, to: original.target, from: original) {
                pendingDestination = nil
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let destination = pendingDestination
            pendingDestination = nil
            guard let url = navigationAction.request.url, BrowserTab.canOpen(url) else { return nil }
            open(url, in: destination)
            return nil
        }

        private func open(_ url: URL, in destination: Destination?) {
            switch destination {
            case .tab: onNewTab(url)
            case .pane: onPane(url)
            case nil: onLink(url)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // The body itself loads, and so does a frame inside it that Mailpit serves, or a blank
            // one. Nothing else may move this view: a form in an email posting from here would put
            // a page from the reader's app where the message was, under headers that no longer
            // describe it. Images are not navigations and never reach this.
            //
            // **A frame from anywhere else is refused**, though JavaScript is off and nothing is
            // stored: an `<iframe>` pointing at the web is a page fetched because an email said
            // so, and mail clients do not load those either, so the preview should not.
            guard let url = navigationAction.request.url else { return .cancel }
            if let destination = pendingDestination {
                pendingDestination = nil
                if BrowserTab.canOpen(url) { open(url, in: destination) }
                return .cancel
            }
            switch navigationAction.navigationType {
            case .linkActivated:
                if BrowserTab.canOpen(url) { onLink(url) }
                return .cancel
            case .other where url == loaded:
                return .allow
            case .other where navigationAction.targetFrame?.isMainFrame == false:
                return url.scheme == "about" || isMailpit(url) ? .allow : .cancel
            default:
                return .cancel
            }
        }

        /// The same scheme, host and port as the body, which is Mailpit.
        private func isMailpit(_ url: URL) -> Bool {
            guard let loaded else { return false }
            return url.scheme == loaded.scheme && url.host() == loaded.host() && url.port == loaded.port
        }
    }
}

/// WebKit builds the native link menu after `menu(for:)`, but before `willOpenMenu`. The menu
/// contains an Open Link in New Window item whose WebKit action carries the link through
/// `WKUIDelegate`. The two Bloom items reuse that action so the original menu stays intact.
private final class MailPreviewWebView: WKWebView {
    var configureLinkMenu: (@MainActor (NSMenu) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        configureLinkMenu?(menu)
    }
}

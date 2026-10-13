import WebKit

/// Reports scroll position at most a few times per second, plus once after scrolling stops. The
/// toolbar uses it to refresh a thin picture of the page edge without snapshotting every frame.
@MainActor
final class BrowserScrollObserver: NSObject, WKScriptMessageHandler {
    static let handlerName = "bloomPageScrolled"

    static let script = """
        (() => {
            let previous;
            let lastReport = 0;
            let trailing;
            const report = () => {
                const offset = Math.max(0, window.scrollY);
                if (offset === previous) return;
                previous = offset;
                window.webkit.messageHandlers.bloomPageScrolled.postMessage(offset);
            };
            window.addEventListener('scroll', () => {
                const now = performance.now();
                if (now - lastReport >= 120) {
                    lastReport = now;
                    report();
                }
                clearTimeout(trailing);
                trailing = setTimeout(report, 120);
            }, { passive: true });
            window.addEventListener('pageshow', report);
            report();
        })();
        """

    weak var owner: BrowserSession?

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let offset = (message.body as? NSNumber)?.doubleValue else { return }
        owner?.setPageScrollOffset(offset)
    }
}

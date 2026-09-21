import Foundation

/// Which visible browser receives Command-L in a split tab.
public enum BrowserLocationTarget {
    /// Prefer the pane the tab remembers as focused, then use the first browser in visual order.
    /// Nil means the selected tab is not a Browser view and Command-L keeps its app-wide meaning.
    public static func resolve<Pane: Equatable>(
        focused: Pane,
        visible: [Pane],
        isBrowser: (Pane) -> Bool
    ) -> Pane? {
        if isBrowser(focused) { return focused }
        return visible.first(where: isBrowser)
    }
}

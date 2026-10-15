import AppKit

/// What the browser toolbar draws for the extension's button. Built by
/// `BrowserExtensionHost.action(for:)`, read by `BrowserToolbarView`, which knows nothing of WebKit.
struct BrowserExtensionAction {
    var icon: NSImage?
    var label: String
    var badge: String
    var isEnabled: Bool
    var perform: @MainActor () -> Void
}

import AppKit
import WebKit

/// The one window a web extension is told about.
///
/// Bloom's browser tabs live in panes inside workspaces rather than in browser windows, and an
/// extension has no use for that structure, so every open tab is reported as being in one normal
/// window, the key window's frame standing in for its geometry.
@MainActor
final class BrowserExtensionWindow: NSObject, WKWebExtensionWindow {
    private var host: BrowserExtensionHost { .shared }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        host.tabs(for: self)
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        host.currentTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        ((NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main)?.frame ?? .null
    }
}

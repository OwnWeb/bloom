import AppKit
import SwiftUI

#if DEBUG
/// Exercises startup and delayed AppKit layout in an unshown window, before app data is loaded.
@MainActor
enum InspectorVisibilityProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--inspector-visibility-probe") }

    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures: [String] = []
        var checks = 0
        func check(_ passed: Bool, _ message: String) {
            checks += 1
            if !passed { failures.append(message) }
        }

        let detail = AnyView(Color.clear)
        let inspector = AnyView(Color.clear)
        let controller = DetailSplitViewController(detail: detail, inspector: inspector)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentViewController = controller
        controller.splitView.autosaveName = nil
        window.contentView?.layoutSubtreeIfNeeded()
        let item = controller.splitViewItems[1]
        let geometry = InspectorGeometry.shared

        func update(_ visible: Bool) {
            controller.update(
                isInspectorPresented: visible, animated: false, content: .home
            )
            window.contentView?.layoutSubtreeIfNeeded()
        }

        update(false)
        check(item.isCollapsed, "closed startup left the inspector expanded")
        check(geometry.width == 0, "closed startup published an inspector width")

        // AppKit can retain a width published before the restored collapse was applied.
        geometry.setInspectorWidth(380)
        update(false)
        check(geometry.width == 0, "an unchanged closed state did not clear stale title-bar geometry")

        // A delayed frame notification must not reopen the header after a requested close.
        // Changing the item's collapsed state would be a real native reopen observed above.
        item.viewController.view.setFrameSize(NSSize(width: 380, height: 600))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: item.viewController.view)
        check(geometry.width == 0, "a late frame notification reopened the hidden inspector header")
        update(false)
        check(item.isCollapsed, "the requested closed state did not override restored AppKit state")

        for _ in 0..<3 {
            update(true)
            check(!item.isCollapsed && geometry.width > 0, "opening did not publish the visible pane width")
            update(false)
            check(item.isCollapsed && geometry.width == 0, "closing left title-bar geometry behind")
        }
        update(true)
        for position: CGFloat in [500, 600, 550] {
            controller.splitView.setPosition(position, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            for pane in controller.splitViewItems.map(\.viewController.view) {
                let host = pane.subviews.first
                check(
                    pane.clipsToBounds && host?.frame.height == pane.bounds.height,
                    "resizing pane did not clip a full-height host"
                )
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        for pane in controller.splitViewItems.map(\.viewController.view) {
            check(pane.subviews.first?.frame == pane.bounds, "host did not fill its pane after resize settled")
        }
        check(!window.isVisible, "the probe displayed a window")

        let result: [String: Any] = ["checks": checks, "failures": failures, "passed": failures.isEmpty]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif

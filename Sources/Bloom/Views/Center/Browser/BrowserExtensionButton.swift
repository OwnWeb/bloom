import AppKit
import SwiftUI

/// The browser extension's own button in the bar: its icon, its badge, and the view its popup
/// hangs from.
///
/// The icon is the extension's, drawn as it ships rather than tinted, because 1Password changes it
/// to say whether the vault is locked and a template rendering would throw that away.
struct BrowserExtensionButton: View {
    var action: BrowserExtensionAction
    /// Handed the button's backing view, for `NSPopover` to point at. See `BrowserSession.extensionAnchor`.
    var anchor: @MainActor (NSView) -> Void

    var body: some View {
        Button(action: action.perform) {
            Group {
                if let icon = action.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "key.fill").foregroundStyle(Palette.textSecondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !action.badge.isEmpty {
                    Text(action.badge)
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 2)
                        .background(Capsule().fill(Palette.accent))
                        .foregroundStyle(.white)
                        .offset(x: 6, y: -5)
                }
            }
            .accessibilityLabel(action.label)
        }
        .buttonStyle(.accessoryBar)
        .disabled(!action.isEnabled)
        .help(action.label)
        .background(PopoverAnchor(report: anchor))
    }
}

/// An empty AppKit view the size of the button, so a popover has something real to point at.
private struct PopoverAnchor: NSViewRepresentable {
    var report: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        report(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        report(nsView)
    }
}

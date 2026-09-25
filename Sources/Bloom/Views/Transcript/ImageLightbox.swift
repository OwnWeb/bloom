import AppKit
import SwiftUI

/// A screenshot gets a whole window, including when it was repeated below a folded turn.
@MainActor
enum ImageLightbox {
    private static var window: NSWindow?

    static let magnifier: NSCursor = {
        guard let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) else {
            return .crosshair
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }()

    static func open(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let viewer = NSHostingView(rootView: ImageLightboxContent(image: image, name: url.lastPathComponent))
        let lightbox: NSWindow
        if let window {
            lightbox = window
        } else {
            lightbox = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            lightbox.isReleasedWhenClosed = false
            lightbox.titleVisibility = .hidden
            lightbox.titlebarAppearsTransparent = true
            lightbox.backgroundColor = .black
            lightbox.minSize = NSSize(width: 420, height: 300)
            let available = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let size = NSSize(width: min(1400, available.width * 0.9),
                              height: min(1000, available.height * 0.9))
            lightbox.setFrame(NSRect(
                x: available.midX - size.width / 2,
                y: available.midY - size.height / 2,
                width: size.width,
                height: size.height
            ), display: false)
            window = lightbox
        }
        lightbox.title = url.lastPathComponent
        lightbox.contentView = viewer
        lightbox.makeKeyAndOrderFront(nil)
    }
}

private struct ImageLightboxContent: View {
    let image: NSImage
    let name: String

    @State private var actualSize = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Group {
                if actualSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .frame(width: image.size.width, height: image.size.height)
                    }
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button(actualSize ? "Fit to Window" : "Actual Size") {
                    actualSize.toggle()
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("Close") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.bordered)
            .padding(16)
        }
        .accessibilityLabel("Screenshot: \(name)")
    }
}

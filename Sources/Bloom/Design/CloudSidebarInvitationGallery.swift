import AppKit
import BloomClient
import SwiftUI

#if DEBUG
/// Photographs the two signed-in Cloud sidebar invitations offscreen at the sidebar's default
/// width. The cards are the real view; only the surrounding section heading is a drawing.
@MainActor
enum CloudSidebarInvitationGallery {
    static func render(into directory: String) -> [String] {
        let states = [
            ("setup", CloudEmptyState(
                title: "One more step first",
                sentence: "SPATIE Technical needs a few things before it can create Bloom Cloud workspaces.",
                steps: ["Connect your GitHub account."],
                action: .open(URL(string: "https://runbloom.app/app/spatie-technical"),
                              title: "Connect GitHub on runbloom.app")
            )),
            ("ready", CloudEmptyState(
                title: "No Bloom Cloud workspaces yet",
                sentence: "Create one for a repository and a branch, and its agent starts work on a machine of its own.",
                action: .createWorkspace
            )),
        ]
        var written: [String] = []
        for (name, state) in states {
            for dark in [false, true] {
                let page = VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    Text("Bloom Cloud workspaces")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                    CloudSidebarInvitationCard(state: state, action: {})
                }
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .background(Palette.sidebar)
                .environment(\.colorScheme, dark ? .dark : .light)
                var image: NSImage?
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(content: page)
                    renderer.scale = 2
                    image = renderer.nsImage
                }
                guard let image, let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let path = "\(directory)/cloud-sidebar-\(name)-\(dark ? "dark" : "light").png"
                try? png.write(to: URL(filePath: path))
                written.append(path)
            }
        }
        return written
    }
}
#endif

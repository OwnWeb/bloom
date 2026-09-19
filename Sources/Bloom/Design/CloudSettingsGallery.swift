import AppKit
import BloomClient
import BloomCore
import SwiftUI

#if DEBUG
/// Settings' Bloom Cloud pane, photographed offscreen: signed out and signed in, light and dark.
///
/// The real `CloudSettingsPane`, not a mock of it, with `.drawn` controls because `ImageRenderer`
/// draws an AppKit-backed button or switch as a placeholder, and with the water held still
/// because the live water is Core Animation. Run by `Tools/review-run-probe.sh --cloud-settings-only`,
/// which opens nothing on screen.
@MainActor
enum CloudSettingsGallery {
    private static let environment = RunbloomEnvironment(origin: RunbloomEnvironment.productionOrigin, urlScheme: "bloom")

    /// An account with one team ready to go and one still setting up, which is the pane's two
    /// kinds of team card side by side.
    private static let account = RunbloomAccount(
        id: "u1", name: "Freek Van der Herten", email: "freek@spatie.be", currentTeamID: "t1",
        githubConnected: true, githubLogin: "freekmurze",
        agentKeys: [AgentKeyStatus(teamID: "t1", agent: "claude", teamKey: true, personalKey: false)],
        teams: [
            RunbloomTeam(id: "t1", name: "Spatie", slug: "spatie", role: "owner", cloudWorkspacesEnabled: true,
                         setup: TeamSetup(enabled: true, setupComplete: true, githubConnected: true,
                                          githubAppInstalled: true, hasProject: true, hasAgentKey: true)),
            RunbloomTeam(id: "t2", name: "Side projects", slug: "side", role: "member", cloudWorkspacesEnabled: true,
                         setup: TeamSetup(enabled: true, setupComplete: false, githubConnected: true,
                                          githubAppInstalled: true, hasProject: false, hasAgentKey: false,
                                          setupURL: URL(string: "https://runbloom.app/app/side"))),
        ]
    )

    /// Bloom's mark, from the bundle's own resources, because the probe bundle has no compiled
    /// icon. Not the installed app's icon through `NSWorkspace`: asking it for one greyed the whole
    /// photograph, measured at 58 per cent on a white ground, whatever was then done with the image.
    private static var mark: NSImage? {
        Bundle.main.url(forResource: "BloomMark", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    }

    static func render(into directory: String) -> [String] {
        let mark = self.mark
        let pages: [(String, CloudSettingsPane.Phase)] = [("cloud-settings-signed-out", .signedOut), ("cloud-settings-signed-in", .signedIn(account))]
        var written: [String] = []
        for (name, phase) in pages {
            for dark in [false, true] {
                let pane = CloudSettingsPane(
                    phase: phase, environment: environment,
                    agentsCreateCloudWorkspaces: .constant(false), drawing: .drawn, actions: .init(),
                    // Read, never written: the installed app's icon is the compiled mark this probe
                    // bundle does not have.
                    mark: mark
                )
                .frame(width: 640)
                .background(Palette.surface)
                .environment(\.colorScheme, dark ? .dark : .light)
                var image: NSImage?
                // The palette resolves through AppKit's appearance as well as SwiftUI's scheme, so
                // both are set for the draw.
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(content: pane)
                    renderer.scale = 2
                    image = renderer.nsImage
                }
                guard let image, let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let path = "\(directory)/\(name)-\(dark ? "dark" : "light").png"
                try? png.write(to: URL(filePath: path))
                written.append(path)
            }
        }
        return written
    }
}
#endif

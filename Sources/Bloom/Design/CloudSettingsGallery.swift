import AppKit
import ImageIO
import BloomClient
import BloomCore
import SwiftUI

#if DEBUG
/// Settings' Bloom Cloud pane, photographed offscreen: signed out and signed in, light and dark,
/// with the question asked before an agent's Bloom Cloud workspace.
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

    static func render(into directory: String) -> [String] {
        let pages: [(String, CloudSettingsPane.Phase)] = [("cloud-settings-signed-out", .signedOut), ("cloud-settings-signed-in", .signedIn(account))]
        var written: [String] = []
        for (name, phase) in pages {
            for dark in [false, true] {
                let pane = CloudSettingsPane(
                    phase: phase, environment: environment,
                    drawing: .drawn, actions: .init()
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
        written += renderQuestion(into: directory)
        written += renderArchive(into: directory)
        return written
    }

    /// The Bloom Cloud delete popover in the three states it passes through, photographed and
    /// measured: as it opens on what runbloom.app knows, once the machine has answered with a
    /// longer list, and when the machine did not answer at all. The height follows each answer;
    /// `CloudArchiveProbe` owns the focused layout and accessibility regression coverage.
    private(set) static var archiveSizes: [CGSize] = []

    private static func renderArchive(into directory: String) -> [String] {
        let fromSummary = CloudArchiveConfirmation(summary: nil)
        var fromMachine = fromSummary
        fromMachine.losses = [
            CloudArchiveConfirmation.conversationSentence,
            "An agent is still working. It will be stopped.",
            "There are uncommitted changes.",
            "3 untracked files.",
            "2 commits have not been pushed.",
        ]
        let states: [(String, CloudArchiveConfirmation, CloudArchivePopoverBody.Status)] = [
            ("open", fromSummary, .asking),
            ("answered", fromMachine, .answered),
            ("unanswered", fromSummary, .unanswered),
        ]
        var written: [String] = []
        archiveSizes = []
        for (name, confirmation, status) in states {
            let body = CloudArchivePopoverBody(
                name: "Reassigning users and teams", confirmation: confirmation, status: status,
                isArchiving: false, onConfirm: {}, onCancel: {}
            )
            .background(Palette.surface)
            let host = NSHostingView(rootView: body)
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()
            archiveSizes.append(host.fittingSize)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let path = "\(directory)/cloud-archive-\(name).png"
            guard (try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))) != nil else { continue }
            written.append(path)
        }
        return written
    }

    /// The question Bloom asks before an agent's Bloom Cloud workspace is created, light and dark.
    ///
    /// Through a hosting view in a window that is never ordered in, and `cacheDisplay`, rather than
    /// `ImageRenderer`, because the sheet's buttons are AppKit's and are the half worth seeing.
    private static func renderQuestion(into directory: String) -> [String] {
        let question = CloudWorkspaceStartQuestion(
            requestedBy: "\u{201C}group occurrences\u{201D}", name: "Port the importer", project: "spatie/flare",
            branch: "freekmurze/port-the-importer", baseBranch: "main", runSetup: true
        )
        var written: [String] = []
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: ConfirmationSheet(
                confirmation: Confirmation(
                    title: question.title, message: question.message,
                    confirmLabel: question.confirmLabel, cancelLabel: question.cancelLabel,
                    tone: .completing, layout: .compact
                ),
                onConfirm: {}, onCancel: {}
            ).background(Palette.surface))
            host.appearance = appearance
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            window.layoutIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let path = "\(directory)/cloud-start-question-\(dark ? "dark" : "light").png"
            guard (try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))) != nil else { continue }
            written.append(path)
        }
        return written
    }
}
#endif

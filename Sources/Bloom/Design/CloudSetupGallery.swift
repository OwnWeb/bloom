import AppKit
import BloomClient
import BloomCore
import BloomProtocol
import SwiftUI

#if DEBUG
/// A new Cloud workspace's setup card, photographed offscreen at each stage the recording of one
/// passed through: the machine being made with the first message waiting, the setup script half
/// way, the resume script at the end, and a failure. Light and dark.
///
/// The real `CloudSetupCard`, handed values rather than a session, which is why it takes values.
/// No project icon, because that one asks the app for its artwork. Run by
/// `Tools/review-run-probe.sh --cloud-setup-only`, which opens nothing on screen.
@MainActor
enum CloudSetupGallery {
    private static let item = CloudWorkspaceItem(
        id: "w1", teamID: "t1", name: "Tickets CSV export", branch: "freekmurze/tickets-csv-export",
        baseBranch: "main", state: "setting_up"
    )

    private static let log = """
    [bloom] Reading the team's environment.
    [bloom] Configuring git.
    [bloom] Cloning the repository.
    Cloning into '/home/sprite/workspace'...
    [bloom] Running the prepare script.
    ==> Installing system packages
        installing php8.5-cli php8.5-bcmath php8.5-pgsql php8.5-intl php8.5-gd
        Installing system packages took 80s
    [bloom] Running the setup script.
    ==> Migrating and seeding the database, building assets, installing Playwright's browsers
        started migrate
        started build
    """

    static func render(into directory: String) -> [String] {
        let now = Date()
        let stages: [(String, SetupRecord?, String, String?, Bool)] = [
            ("machine", nil, "", "Add a CSV export to the tickets overview", false),
            ("setup", SetupRecord(state: "running", step: "setup"), log, nil, true),
            ("resume", SetupRecord(state: "running", step: "resume"),
             log + "[bloom] Running the resume script.\n==> Starting databases\n    Postgres is already running\n", nil, true),
            ("failed", SetupRecord(state: "failed", step: "setup", note: "SQLSTATE[08006] connection to server at \"127.0.0.1\", port 5432 failed"),
             "", nil, true),
        ]
        var written: [String] = []
        for (name, setup, text, held, isConnected) in stages {
            guard let progress = CloudSetupProgress.of(
                setup: setup, log: text, isConnected: isConnected, repository: "spatie/there-there.app"
            ) else { continue }
            var clock = CloudSetupClock()
            // A window that watched the start: the machine took 24 seconds and the rest followed.
            clock.observe(.machine, at: now.addingTimeInterval(-200))
            if progress.activeStep != .machine {
                clock.observe(.connect, at: now.addingTimeInterval(-176))
                clock.observe(.clone, at: now.addingTimeInterval(-175))
                if let active = progress.activeStep, active != .clone { clock.observe(active, at: now.addingTimeInterval(-150)) }
            }
            let card = CloudSetupCard(
                progress: progress, item: item, clock: clock,
                anchors: [.machine: now.addingTimeInterval(-200)], startedAt: now.addingTimeInterval(-200),
                log: text, heldPrompt: held,
                actions: .init(stop: {}, runAgain: {})
            )
            for dark in [false, true] {
                let page = VStack(spacing: 0) {
                    Color.clear.frame(height: TranscriptLayout.topSpace)
                    card
                }
                .frame(width: 760)
                .background(Palette.surface)
                .environment(\.colorScheme, dark ? .dark : .light)
                var image: NSImage?
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(content: page)
                    renderer.scale = 2
                    image = renderer.nsImage
                }
                guard let image, let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let path = "\(directory)/cloud-setup-\(name)-\(dark ? "dark" : "light").png"
                try? png.write(to: URL(filePath: path))
                written.append(path)
            }
        }
        return written
    }
}
#endif

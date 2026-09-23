import AppKit
import BloomClient
import BloomCore
import SwiftUI

#if DEBUG
/// The Ports popover of a Cloud workspace, photographed offscreen in each state a row passes
/// through, light and dark, and the toolbar glyph with and without its dot.
///
/// `CloudPortsList`, handed values rather than a `CloudPorts`, which is why the popover's contents
/// take values: a workspace, a machine and a forward are not needed to see what a forward looks
/// like. The Open choices are the labels a Mac with TablePlus installed would get, because asking
/// LaunchServices here would photograph this Mac rather than the design.
///
/// Through a hosting view in a window that is never ordered in, and `cacheDisplay`, as the Cloud
/// settings gallery draws its archive popover, because the row's buttons and the port field are
/// AppKit's and `ImageRenderer` draws those as placeholders. Run by
/// `Tools/review-run-probe.sh --cloud-ports-only`, which opens nothing on screen.
@MainActor
enum CloudPortsGallery {
    private static func row(_ number: Int, _ forward: PortForward.State? = nil, reserved: Bool = false) -> CloudPorts.Row {
        CloudPorts.Row(port: WorkspacePorts.port(number, reserved: reserved), forward: forward)
    }

    private static func local(_ number: Int) -> Int {
        WorkspacePorts.localCandidates(workspace: "01k5a7d3v1x0m8n2q4r6s9t0wy", port: number)[0]
    }

    /// The popover as a real workspace answered it on 24 September 2026: two databases, two web
    /// servers, two unnamed ports and three of Bloom's own, which the popover hides.
    private static var listing: [CloudPorts.Row] {
        [
            row(3000), row(5173), row(5432), row(6379),
            row(8080, reserved: true), row(8081, reserved: true), row(8082), row(8090), row(41_029, reserved: true),
        ]
    }

    /// The same, with PostgreSQL forwarded.
    private static var connected: [CloudPorts.Row] {
        listing.map { $0.id == 5432 ? row(5432, .live(localPort: local(5432))) : $0 }
    }

    /// Each state the popover passes through, in the order a person meets them, and whether "more
    /// ports" and the port field are open.
    private static var states: [(name: String, rows: [CloudPorts.Row], problem: String?, more: Bool, manual: Bool)] {
        [
            ("listing", listing, nil, false, false),
            ("opening", listing.map { $0.id == 5432 ? row(5432, .opening) : $0 }, nil, false, false),
            ("live", connected, nil, false, false),
            ("expanded", connected, nil, true, true),
            ("web-only", [row(3000), row(5173, .live(localPort: local(5173))), row(8081, reserved: true)], nil, false, false),
            ("no-local-port", [row(9000, .failed("No local port was free for this forward."))], nil, false, false),
            ("refused", [row(8081, .refused("Bloom uses port 8081 on this machine, so it cannot be forwarded."))], nil, false, false),
            ("empty", [], nil, false, false),
            ("unreadable", [], "This Bloom Cloud workspace is running a version of Bloom Runner that cannot list its ports yet.", false, false),
        ]
    }

    private static func choices(for row: CloudPorts.Row) -> [CloudPortRow.OpenChoice] {
        switch row.opening {
        case .browser: return [CloudPortRow.OpenChoice(title: "Open") {}]
        case .application: return [
            CloudPortRow.OpenChoice(title: "Open in TablePlus") {},
            CloudPortRow.OpenChoice(title: "Open in Postico 2") {},
        ]
        case nil: break
        }
        guard row.forward == nil, WorkspacePorts.clientProbe(row.port) != nil else { return [] }
        return [CloudPortRow.OpenChoice(title: "Open in TablePlus") {}]
    }

    static func render(into directory: String) -> [String] {
        var written: [String] = []
        for state in states {
            for dark in [false, true] {
                let list = CloudPortsList(
                    rows: state.rows, problem: state.problem, isLoading: false, copied: nil,
                    actions: CloudPortsList.Actions(choices: choices),
                    showsMore: state.more, showsManual: state.manual
                )
                .background(Palette.surface)
                if let path = draw(list, dark: dark, to: "\(directory)/cloud-ports-\(state.name)-\(dark ? "dark" : "light").png") {
                    written.append(path)
                }
            }
        }
        for dark in [false, true] {
            let icons = HStack(spacing: 24) {
                CloudPortsIcon(isForwarding: false)
                CloudPortsIcon(isForwarding: true)
            }
            .font(.title2)
            .padding(16)
            .background(Palette.surface)
            if let path = draw(icons, dark: dark, to: "\(directory)/cloud-ports-toolbar-\(dark ? "dark" : "light").png") {
                written.append(path)
            }
        }
        return written
    }

    private static func draw(_ view: some View, dark: Bool, to path: String) -> String? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.layoutIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard (try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))) != nil else { return nil }
        return path
    }
}
#endif

import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// The ports of a Cloud workspace, and forwarding one to this Mac.
///
/// **A list of what is listening, not a settings pane.** Every row is a port inside the workspace;
/// the button on it either opens a forward or copies the `localhost` address of one that is open.
/// Nothing here is a preference, so nothing here is saved: a forward lives as long as somebody
/// wants it and no longer.
///
/// **The address is the product.** A person came here to paste something into TablePlus, so the
/// live row leads with `localhost:43217` in a monospaced pill and copies on a click. Open sits
/// beside it for a port Bloom can hand on: a web server to the workspace's own browser pane, a
/// database to whichever installed application registers its scheme. Stopping a forward is on the
/// row's context menu, because it is the rare act and the row has room for two buttons, not three.
struct CloudPortsPopover: View {
    var ports: CloudPorts
    @State private var copied: Int?

    var body: some View {
        CloudPortsList(
            rows: ports.rows,
            problem: ports.problem,
            isLoading: ports.isLoading,
            copied: copied,
            actions: CloudPortsList.Actions(
                copy: copy,
                forward: ports.forward,
                stop: ports.stop,
                choices: choices
            )
        )
        .task { await ports.load() }
    }

    private func copy(_ row: CloudPorts.Row) {
        guard let local = row.localPort else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("localhost:\(local)", forType: .string)
        copied = row.port.number
        Task {
            // Long enough to read, short enough that the button is itself again by the time
            // somebody looks back at it.
            try? await Task.sleep(for: .seconds(2))
            if copied == row.port.number { copied = nil }
        }
    }

    /// What Open offers for a row, first choice first. Empty is no Open button at all.
    private func choices(for row: CloudPorts.Row) -> [CloudPortRow.OpenChoice] {
        switch row.opening {
        case .browser:
            [CloudPortRow.OpenChoice(title: "Open") { ports.openPage(row) }]
        case .application(let url):
            InstalledApps.handlers(for: url).map { app in
                CloudPortRow.OpenChoice(title: "Open in \(app.app.name)") { OpenIn.open(url, with: app) }
            }
        case nil:
            []
        }
    }
}

/// The popover's contents, from values rather than from the model, so `CloudPortsGallery` can draw
/// every state of it without a workspace behind it.
struct CloudPortsList: View {
    struct Actions {
        var copy: (CloudPorts.Row) -> Void = { _ in }
        var forward: (Int) -> Void = { _ in }
        var stop: (Int) -> Void = { _ in }
        var choices: (CloudPorts.Row) -> [CloudPortRow.OpenChoice] = { _ in [] }
    }

    var rows: [CloudPorts.Row]
    var problem: String?
    var isLoading: Bool
    var copied: Int?
    var actions: Actions
    @State private var manualPort = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header
            if let problem {
                Text(problem)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if rows.isEmpty {
                empty
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        CloudPortRow(
                            row: row,
                            copied: copied == row.port.number,
                            choices: actions.choices(row),
                            act: { act(on: row) },
                            stop: { actions.stop(row.port.number) }
                        )
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }
            manual
            Text("A forwarded port is reachable from this Mac and from nowhere else.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(16)
        // Wider than the mockup's 390, because a live database row carries the address and "Open
        // in TablePlus" side by side at the app's own type sizes, and at 390 the address was the
        // one that gave way, which is the one thing on the row somebody came for.
        .frame(width: 440)
    }

    private var header: some View {
        HStack {
            Text("Ports").font(Typo.title)
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
        }
    }

    private var empty: some View {
        HStack(alignment: .top, spacing: Metrics.spacingWide) {
            Image(systemName: "circle.dashed")
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                Text("Nothing listening").font(Typo.label)
                Text("Nothing in this workspace is listening on a port yet. Start your app or database and look again.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Metrics.spacing)
    }

    /// Naming a port by hand, because a service that started after the list was read is ordinary
    /// and a list you cannot add to is a wall.
    private var manual: some View {
        HStack(spacing: Metrics.spacing) {
            TextField("Forward another port", text: $manualPort)
                .textFieldStyle(.roundedBorder)
                .onSubmit(forwardManualPort)
            Button("Forward", action: forwardManualPort)
                .disabled(Int(manualPort.trimmingCharacters(in: .whitespaces)) == nil)
        }
    }

    private func forwardManualPort() {
        guard let port = Int(manualPort.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(port) else { return }
        manualPort = ""
        actions.forward(port)
    }

    /// The main button a row has, which depends on what it is doing.
    private func act(on row: CloudPorts.Row) {
        if row.localPort != nil {
            actions.copy(row)
        } else if row.forward == nil {
            actions.forward(row.port.number)
        } else {
            actions.stop(row.port.number)
        }
    }
}

/// One port: what it is, what Bloom is doing about it, and the things to click.
struct CloudPortRow: View {
    /// One way to open a live forward: its label, which names the application and so tells two
    /// apart, and what it does.
    struct OpenChoice {
        let title: String
        let perform: () -> Void
    }

    var row: CloudPorts.Row
    var copied: Bool
    var choices: [OpenChoice] = []
    var act: () -> Void
    var stop: () -> Void = {}

    var body: some View {
        HStack(spacing: Metrics.spacingWide) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                Text(row.port.title).font(Typo.label)
                Text(subtitle)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Metrics.spacing)
            action
        }
        .padding(.vertical, Metrics.spacing)
        .contentShape(Rectangle())
        .contextMenu {
            if row.localPort != nil {
                Button("Copy Address", action: act)
            }
            if row.forward != nil {
                Button("Stop Forwarding", action: stop)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if row.port.reserved {
            EmptyView()
        } else if let local = row.localPort {
            liveActions(local)
                // Small, as the mockup draws them: a live row carries two controls beside a name,
                // and at the regular size the sentence under the name wrapped onto three lines.
                .controlSize(.small)
        } else if case .opening = row.forward {
            ProgressView().controlSize(.small)
        } else {
            Button(row.forward == nil ? "Forward" : "Stop", action: act)
        }
    }

    private func liveActions(_ local: Int) -> some View {
        HStack(spacing: Metrics.spacing) {
            // Verbatim, because a title with a number in it is a localised string, and on a Mac set
            // to Dutch it drew `localhost:43.217`: an address with a thousands separator in it,
            // which is not the address the button copies.
            Button(action: act) {
                Text(verbatim: copied ? "Copied" : "localhost:\(local)")
                    .font(Typo.codeSmall)
            }
            .fixedSize()
            .help("Copy the address for a client on this Mac")
            open
        }
        // The name and the sentence under it wrap; the address never does.
        .layoutPriority(1)
    }

    /// Open, when there is anything to open the forward with. Several applications that take the
    /// same database are one button with the rest behind it, the default first.
    @ViewBuilder
    private var open: some View {
        if let first = choices.first {
            if choices.count == 1 {
                Button(first.title, action: first.perform)
            } else {
                Menu(first.title) {
                    ForEach(choices.dropFirst(), id: \.title) { choice in
                        Button(choice.title, action: choice.perform)
                    }
                } primaryAction: {
                    first.perform()
                }
                .fixedSize()
            }
        }
    }

    private var symbol: String {
        switch row.port.kind {
        case .database: "cylinder"
        case .http: "globe"
        case .other: "point.3.connected.trianglepath.dotted"
        }
    }

    private var tint: Color {
        switch row.forward {
        case .live: Palette.accent
        case .failed, .refused: Palette.warning
        default: Palette.textSecondary
        }
    }

    /// The line under the name, which is the only place a failure gets to speak.
    private var subtitle: String {
        if row.port.reserved { return "Bloom uses this port, so it cannot be forwarded." }
        switch row.forward {
        case .live: return "Forwarded from port \(row.port.number)"
        case .opening: return "Opening…"
        case .refused(let reason), .failed(let reason): return reason
        case nil: return "Listening on \(row.port.number)"
        }
    }
}

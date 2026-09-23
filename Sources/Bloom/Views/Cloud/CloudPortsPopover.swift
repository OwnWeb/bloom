import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// The ports of a Cloud workspace, and forwarding one to this Mac.
///
/// **A list of what is listening, not a settings pane.** Every row is a port inside the workspace;
/// nothing here is a preference, so nothing here is saved: a forward lives as long as somebody
/// wants it and no longer.
///
/// **One line a port, databases first.** The first version gave every port two lines and listed
/// them by number, so on a real workspace the database somebody opened the popover for was the
/// third of nine rows, under two web servers, above four of Bloom's own ports that could not be
/// forwarded. Now a database leads, web servers and unnamed ports fold behind one line, and
/// Bloom's own are not shown. The order is `WorkspacePorts.arrange`, where it is tested.
///
/// **Open forwards and opens in one click.** A database a client application registers the
/// scheme of gets "Open in TablePlus" before anything is forwarded; the forward is started, and
/// the application handed the connection once it is live. Copying is an icon whose tooltip is
/// the exact text it copies, because a pill with a menu arrow on it read as a control nobody could
/// name. The rare acts, copying only the port and stopping, are on the row's context menu.
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
                forward: { ports.forward($0) },
                stop: ports.stop,
                choices: choices
            )
        )
        .task { await ports.load() }
    }

    private func copy(_ row: CloudPorts.Row, _ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = row.port.number
        Task {
            // Long enough to read, short enough that the button is itself again by the time
            // somebody looks back at it.
            try? await Task.sleep(for: .seconds(2))
            if copied == row.port.number { copied = nil }
        }
    }

    /// What Open offers for a row, first choice first. Empty is no Open button at all.
    ///
    /// A database that is not forwarded yet is asked about by its scheme alone, and its choices
    /// forward first and open once the forward is live.
    private func choices(for row: CloudPorts.Row) -> [CloudPortRow.OpenChoice] {
        switch row.opening {
        case .browser:
            return [CloudPortRow.OpenChoice(title: "Open") { ports.openPage(row) }]
        case .application(let url):
            return InstalledApps.handlers(for: url).map { app in
                CloudPortRow.OpenChoice(title: "Open in \(app.app.name)") { OpenIn.open(url, with: app) }
            }
        case nil:
            break
        }
        guard row.forward == nil, let probe = WorkspacePorts.clientProbe(row.port) else { return [] }
        return InstalledApps.handlers(for: probe).map { app in
            CloudPortRow.OpenChoice(title: "Open in \(app.app.name)") {
                ports.forward(row.port.number) { live in
                    if case .application(let url) = live.opening { OpenIn.open(url, with: app) }
                }
            }
        }
    }
}

/// The popover's contents, from values rather than from the model, so `CloudPortsGallery` can draw
/// every state of it without a workspace behind it.
struct CloudPortsList: View {
    struct Actions {
        var copy: (CloudPorts.Row, String) -> Void = { _, _ in }
        var forward: (Int) -> Void = { _ in }
        var stop: (Int) -> Void = { _ in }
        var choices: (CloudPorts.Row) -> [CloudPortRow.OpenChoice] = { _ in [] }
    }

    var rows: [CloudPorts.Row]
    var problem: String?
    var isLoading: Bool
    var copied: Int?
    var actions: Actions
    @State private var showsMore: Bool
    @State private var showsManual: Bool
    @State private var manualPort = ""
    @FocusState private var manualFocused: Bool

    init(
        rows: [CloudPorts.Row], problem: String?, isLoading: Bool, copied: Int?, actions: Actions,
        showsMore: Bool = false, showsManual: Bool = false
    ) {
        self.rows = rows
        self.problem = problem
        self.isLoading = isLoading
        self.copied = copied
        self.actions = actions
        _showsMore = State(initialValue: showsMore)
        _showsManual = State(initialValue: showsManual)
    }

    /// The rows split as `WorkspacePorts.arrange` splits their ports.
    private var arranged: (leading: [CloudPorts.Row], more: [CloudPorts.Row]) {
        let forwarded = Set(rows.filter { $0.forward != nil }.map(\.id))
        let arrangement = WorkspacePorts.arrange(rows.map(\.port), forwarded: forwarded)
        let byNumber = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return (arrangement.leading.compactMap { byNumber[$0.number] }, arrangement.more.compactMap { byNumber[$0.number] })
    }

    var body: some View {
        let arranged = arranged
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            header
            if let problem {
                Text(problem)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if arranged.leading.isEmpty {
                empty
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(arranged.leading) { row(for: $0, folded: false) }
                }
                if !arranged.more.isEmpty {
                    Divider()
                    more(arranged.more)
                }
            }
            if showsManual { manual }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 340)
    }

    private func row(for row: CloudPorts.Row, folded: Bool) -> some View {
        CloudPortRow(
            row: row,
            folded: folded,
            copied: copied == row.port.number,
            choices: actions.choices(row),
            copy: { actions.copy(row, $0) },
            forward: { actions.forward(row.port.number) },
            stop: { actions.stop(row.port.number) }
        )
    }

    private var header: some View {
        HStack(spacing: Metrics.spacing) {
            Text("Ports")
                .font(Typo.labelEmphasis)
                .help("A forwarded port is reachable from this Mac and from nowhere else.")
            if isLoading { ProgressView().controlSize(.mini) }
            Spacer()
            Button {
                showsManual.toggle()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Forward a port by its number")
            .accessibilityLabel("Forward another port")
        }
    }

    private func more(_ rows: [CloudPorts.Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsMore.toggle() }
            } label: {
                HStack(spacing: Metrics.spacingSmall) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(showsMore ? 90 : 0))
                    Text(rows.count == 1 ? "1 more port" : "\(rows.count) more ports")
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, Metrics.spacingSmall)
            if showsMore {
                ForEach(rows) { row(for: $0, folded: true) }
            }
        }
    }

    private var empty: some View {
        Text("Nothing in this workspace is listening on a port yet. Start your app or database and look again.")
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Metrics.spacingSmall)
    }

    /// Naming a port by hand, because a service that started after the list was read is ordinary
    /// and a list you cannot add to is a wall. Behind the header's plus, because it is the rare
    /// case and a text field is the heaviest thing a popover can hold.
    private var manual: some View {
        HStack(spacing: Metrics.spacing) {
            TextField("Port number", text: $manualPort)
                .textFieldStyle(.roundedBorder)
                .focused($manualFocused)
                .onSubmit(forwardManualPort)
                .onAppear { manualFocused = true }
            Button("Forward", action: forwardManualPort)
                .disabled(Int(manualPort.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .controlSize(.small)
        .padding(.top, Metrics.spacingSmall)
    }

    private func forwardManualPort() {
        guard let port = Int(manualPort.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(port) else { return }
        manualPort = ""
        showsManual = false
        actions.forward(port)
    }
}

/// One port on one line: what it is, where it landed on this Mac, and the thing to click.
struct CloudPortRow: View {
    /// One way to open a port: its label, which names the application and so tells two apart, and
    /// what it does.
    struct OpenChoice {
        let title: String
        let perform: () -> Void
    }

    var row: CloudPorts.Row
    /// Whether the row sits behind "more ports", where Forward is quieter than on a leading row.
    var folded = false
    var copied: Bool
    var choices: [OpenChoice] = []
    var copy: (String) -> Void = { _ in }
    var forward: () -> Void = {}
    var stop: () -> Void = {}

    /// What the copy button copies, when the forward is live.
    private var address: String? {
        row.localPort.map { WorkspacePorts.address(row.port, localPort: $0) }
    }

    /// The sentence a refused or failed forward has, which is the only second line a row gets.
    private var problem: String? {
        switch row.forward {
        case .refused(let reason), .failed(let reason): reason
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: Metrics.spacingWide) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
                    Text(row.port.title)
                        .font(folded ? Typo.label : Typo.labelEmphasis)
                        .lineLimit(1)
                    number
                }
                if let problem {
                    Text(problem)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Metrics.spacing)
            action
                .controlSize(.small)
                .layoutPriority(1)
        }
        .padding(.vertical, folded ? Metrics.spacingSmall : Metrics.spacing)
        .contentShape(Rectangle())
        .contextMenu {
            if let address, let local = row.localPort {
                Button("Copy \(address)") { copy(address) }
                // Verbatim, for the reason the number beside the name is.
                Button { copy(String(local)) } label: { Text(verbatim: "Copy Port \(local)") }
            }
            if row.forward != nil {
                Button("Stop Forwarding", action: stop)
            }
        }
    }

    /// The port beside the name: the remote one while nothing is forwarded, the local one after,
    /// in green because that is the number a client connects to. An unnamed port's title is its
    /// number already. Verbatim, because a number in a localised string drew `41.499` on a Mac set
    /// to Dutch, which is not the port.
    @ViewBuilder
    private var number: some View {
        if let local = row.localPort {
            Text(verbatim: "→ \(local)")
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.accent)
                .help("Forwarded from port \(String(row.port.number)) to port \(String(local)) on this Mac")
        } else if row.port.name != nil {
            Text(verbatim: String(row.port.number))
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        if row.localPort != nil {
            HStack(spacing: Metrics.spacingSmall) {
                copyButton
                open
            }
        } else if case .opening = row.forward {
            ProgressView().controlSize(.small)
        } else if row.forward != nil {
            Button("Stop", action: stop)
        } else if !choices.isEmpty {
            open
        } else if folded {
            Button("Forward", action: forward)
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.textSecondary)
        } else {
            Button("Forward", action: forward)
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        if copied {
            Text("Copied")
                .font(Typo.caption)
                .foregroundStyle(Palette.accent)
        } else if let address {
            Button { copy(address) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(address)")
            .accessibilityLabel("Copy \(address)")
        }
    }

    /// Open, when there is anything to open the port with. A live row says only "Open", because
    /// its width is taken by the address, and its tooltip names the application. Several
    /// applications that take the same database are one button with the rest behind it.
    @ViewBuilder
    private var open: some View {
        if let first = choices.first {
            let title = row.localPort == nil ? first.title : "Open"
            if choices.count == 1 {
                Button(title, action: first.perform)
                    .help(first.title)
            } else {
                Menu(title) {
                    ForEach(choices, id: \.title) { choice in
                        Button(choice.title, action: choice.perform)
                    }
                } primaryAction: {
                    first.perform()
                }
                .fixedSize()
                .help(first.title)
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
}

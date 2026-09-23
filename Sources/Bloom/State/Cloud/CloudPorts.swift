import BloomClient
import BloomCore
import BloomProtocol
import Foundation

/// The ports of one Cloud workspace, and the forwards a person has opened to this Mac.
///
/// **Kept per workspace and alive past the popover.** A forward outlives the window it was opened
/// from: somebody flips Postgres on, shuts the popover, and works in TablePlus for an hour. So the
/// model belongs to the session rather than to the view, and closing the popover closes nothing.
///
/// **The naming is `WorkspacePorts`, in the core, where it is tested.** This type is the part that
/// cannot be: a list read over the wire, and actors holding sockets.
@MainActor
@Observable
final class CloudPorts {
    /// One row: what is listening, and what Bloom is doing about it.
    struct Row: Identifiable, Sendable {
        var port: WorkspacePorts.Port
        var forward: PortForward.State?

        var id: Int { port.number }

        /// Whether a person can act on this row at all.
        var isForwardable: Bool { !port.reserved }

        /// The local address, when there is one to copy.
        var localPort: Int? {
            if case .live(let port) = forward { port } else { nil }
        }

        /// What the row's Open hands the forward to, when there is anything to hand it to. The
        /// decision is `WorkspacePorts.opening`, where it is tested.
        var opening: WorkspacePorts.Opening? {
            localPort.flatMap { WorkspacePorts.opening(port, localPort: $0) }
        }
    }

    private(set) var rows: [Row] = []
    /// Why the list could not be read, or nil when it could.
    private(set) var problem: String?
    private(set) var isLoading = false

    private weak var session: CloudWorkspaceSession?
    private let workspaceID: CloudWorkspaceID
    private var forwards: [Int: PortForward] = [:]
    private var watchers: [Int: Task<Void, Never>] = [:]

    init(workspaceID: CloudWorkspaceID, session: CloudWorkspaceSession?) {
        self.workspaceID = workspaceID
        self.session = session
    }

    /// Whether anything is forwarded, which is what the toolbar button shows when it is shut.
    var hasLiveForward: Bool {
        rows.contains { $0.localPort != nil }
    }

    /// Asks the machine what is listening. Called every time the popover opens, because a service
    /// that started a minute ago is the common case and a stale list is the useless one.
    func load() async {
        guard let session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await session.perform(.listeningPorts)
            guard case .ports(let ports) = result else {
                problem = "This Bloom Cloud workspace answered something unexpected."
                return
            }
            problem = nil
            discovered = WorkspacePorts.describe(ports.map { (port: $0.port, reserved: $0.reserved) })
            rebuild()
        } catch {
            // A workspace too old to know the operation, or one that is not answering. Either way
            // the honest row is none, with the machine's own sentence above them.
            problem = error.message
        }
    }

    /// The rows: what the machine last said is listening, plus any port this Mac is forwarding
    /// that has since stopped listening.
    ///
    /// **A forward whose service died keeps its row.** It is still holding a local port, so hiding
    /// it would leave somebody with a `localhost` address that answers and nothing in the window
    /// that admits it exists.
    private func rebuild() {
        var ports = discovered
        for port in forwards.keys where !ports.contains(where: { $0.number == port }) {
            ports.append(WorkspacePorts.port(port))
        }
        rows = ports.sorted().map { Row(port: $0, forward: forwards[$0.number] == nil ? nil : states[$0.number]) }
    }

    private var discovered: [WorkspacePorts.Port] = []
    private var states: [Int: PortForward.State] = [:]

    /// Opens a forward of one port to this Mac.
    ///
    /// A port the machine has said is Bloom's own is not even tried: the machine would refuse it on
    /// the first connection, and a row that turned red only once somebody pointed a client at it
    /// would be a refusal nobody was watching for.
    func forward(_ port: Int) {
        guard forwards[port] == nil, let session else { return }
        guard !discovered.contains(where: { $0.number == port && $0.reserved }) else { return }
        let forward = PortForward(
            remotePort: port,
            localCandidates: WorkspacePorts.localCandidates(workspace: workspaceID.rawValue, port: port)
        ) { [weak session] in
            guard let token = await session?.sessionToken(), token.allows("terminal") else { return nil }
            return (machine: token.machineURL, token: token.token)
        }
        forwards[port] = forward
        states[port] = .opening
        rebuild()
        watchers[port] = Task { [weak self] in
            for await state in forward.states {
                guard let self else { return }
                self.states[port] = state
                self.rebuild()
            }
        }
        Task { await forward.start() }
    }

    /// Closes a forward. The machine is not told: a forward is a thing on this Mac, and the socket
    /// closing is what the machine sees.
    func stop(_ port: Int) {
        watchers.removeValue(forKey: port)?.cancel()
        states.removeValue(forKey: port)
        guard let forward = forwards.removeValue(forKey: port) else { return }
        Task { await forward.stop() }
        rebuild()
    }

    /// Shows a forwarded page in the workspace's own browser pane. A database's opening is handed to
    /// another application by the popover, through `OpenIn`, because that is a view's business with
    /// `NSWorkspace` rather than this model's.
    func openPage(_ row: Row) {
        guard case .browser(let url) = row.opening else { return }
        session?.openForwardedPage(url, title: row.port.title)
    }

    /// The address a database client is handed, with the login the project's `.env` gives it.
    ///
    /// Read at the click rather than with the list, because the file is the project's and can
    /// change under an open popover, and because a list that read it would be reading a secret for
    /// every row nobody opens. No `.env`, or one that says nothing, is the address without a login,
    /// which is what Open handed on before there was one.
    func applicationURL(_ row: Row) async -> URL? {
        guard let local = row.localPort, case .application(let bare) = row.opening else { return nil }
        guard let scheme = row.port.scheme, let session,
              let result = try? await session.perform(.file(path: ".env")), case .file(let record) = result,
              let login = DatabaseLogin.from(dotenv: record.text, scheme: scheme),
              case .application(let url) = WorkspacePorts.opening(row.port, localPort: local, login: login) else { return bare }
        return url
    }

    /// Closes every forward, for a workspace going away.
    func stopAll() {
        for port in forwards.keys { stop(port) }
    }
}

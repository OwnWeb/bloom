import AppKit
import BloomClient
import BloomCore
import Observation

/// The reader's terminal in a Cloud workspace: a shell on the machine, registered as a turn under
/// their own token, so it has their agent keys and pushes as them.
///
/// The view is kept here rather than made by the pane, so switching to a chat and back does not
/// lose the scrollback. The socket is not kept open for its own sake: it closes when the machine
/// sleeps, and the next keystroke opens it again, which wakes the machine and redraws the shell,
/// since the shell itself lived on.
@MainActor
@Observable
final class CloudTerminal {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        /// Closed by the machine. The sentence is its reason, when it gave one.
        case disconnected(String?)
        /// Refused: no terminal ability, or access went away. Reconnecting will not help.
        case refused(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private weak var session: CloudWorkspaceSession?
    @ObservationIgnored private var socket: TerminalSocket?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private var size: (columns: Int, rows: Int) = (80, 24)
    @ObservationIgnored private(set) lazy var view: CloudTerminalView = {
        let view = CloudTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.onInput = { [weak self] bytes in self?.input(bytes) }
        view.onResize = { [weak self] columns, rows in self?.resized(columns: columns, rows: rows) }
        return view
    }()

    init(session: CloudWorkspaceSession) {
        self.session = session
    }

    /// Connects, unless connected or refused.
    func connect() {
        switch state {
        case .connecting, .connected, .refused: return
        default: break
        }
        guard let session else { return }
        state = .connecting
        Task { [weak self] in
            guard let self else { return }
            guard let token = await session.sessionToken() else {
                state = .disconnected("This Cloud workspace is not ready for a terminal yet.")
                return
            }
            guard token.allows("terminal") else {
                state = .refused("Your access to this Cloud workspace does not include the terminal.")
                return
            }
            let socket = TerminalSocket(machine: token.machineURL, name: TerminalSocket.name(for: session.readerID), token: token.token)
            self.socket = socket
            state = .connected
            await socket.resize(columns: size.columns, rows: size.rows)
            listen(to: socket)
        }
    }

    private func listen(to socket: TerminalSocket) {
        reader = Task { [weak self] in
            for await event in socket.events {
                guard let self else { return }
                switch event {
                case .output(let data):
                    self.view.feed(byteArray: ArraySlice(data))
                case .closed(let reason, let isRefusal):
                    self.socket = nil
                    self.refresher?.cancel()
                    self.state = isRefusal ? .refused(reason ?? "The terminal was refused.") : .disconnected(reason)
                }
            }
        }
        refresher = Task { [weak self] in
            // Four minutes into a five minute token, a fresh one.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(240))
                guard let self, let session = self.session, !Task.isCancelled,
                      let fresh = await session.sessionToken(forceRefresh: true) else { return }
                await self.socket?.reauthenticate(token: fresh.token)
            }
        }
    }

    func close() {
        reader?.cancel()
        refresher?.cancel()
        let socket = socket
        self.socket = nil
        Task { await socket?.close() }
        if case .refused = state { return }
        state = .idle
    }

    /// Clears a refusal so the next connect tries again, for after sharing or a sign in changed.
    func retry() {
        if case .refused = state { state = .idle }
        connect()
    }

    private func input(_ bytes: ArraySlice<UInt8>) {
        guard let socket else {
            // A keystroke into a closed terminal is what reopens it. The keystroke itself is not
            // replayed: the shell redraws on reconnect, and a key pressed into a screen that was
            // not there is not a key anybody meant.
            connect()
            return
        }
        let data = Data(bytes)
        Task { await socket.send(data) }
    }

    private func resized(columns: Int, rows: Int) {
        size = (columns, rows)
        guard let socket else { return }
        Task { await socket.resize(columns: columns, rows: rows) }
    }
}

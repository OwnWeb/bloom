import BloomProtocol
import Foundation

/// One terminal on a Cloud workspace's machine, over `GET /_bloom/v1/terminal?name=`.
///
/// The token goes in the first text frame, never in the URL or a header, because a browser cannot
/// send a header on a WebSocket and every client takes the one path. After that, binary frames are
/// keystrokes out and screen output in, and text frames are `resize` and `reauth`. The shell lives
/// on after the socket closes, so reconnecting with the same name redraws the screen.
public actor TerminalSocket {
    public enum Event: Sendable, Hashable {
        case output(Data)
        /// The socket closed. `reason` is the machine's sentence when it gave one, and `isRefusal`
        /// says the token or the ability was refused, which reconnecting will not fix.
        case closed(reason: String?, isRefusal: Bool)
    }

    private let task: URLSessionWebSocketTask
    private var isClosed = false
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    /// Opens the socket and authenticates. Output starts arriving on `events` straight away.
    public init(machine: URL, name: String, token: String, session: URLSession = .shared) {
        task = session.webSocketTask(with: Self.url(machine: machine, name: name))
        task.maximumMessageSize = 1 << 20
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(4_096))
        task.resume()
        let task = task
        Task { await self.start(token: token, task: task) }
    }

    /// The address of a terminal. A name is letters, digits, hyphens and underscores, up to 64.
    public static func url(machine: URL, name: String) -> URL {
        var components = URLComponents(url: machine.appending(path: "_bloom/v1/terminal"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url!
    }

    /// The text of a control frame, as the wire spells it.
    public static func text(_ frame: TerminalControlFrame) -> String {
        (try? WireJSON.encode(frame)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// A terminal name that belongs to one person, so two collaborators each get a shell of their
    /// own, with their own key and GitHub identity, rather than typing into each other's.
    public static func name(for userID: String?) -> String {
        let allowed = (userID ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return allowed.isEmpty ? "shell" : "shell-" + String(allowed.prefix(40))
    }

    private func start(token: String, task: URLSessionWebSocketTask) async {
        do {
            try await task.send(.string(Self.text(.auth(token: token))))
        } catch {
            finish(reason: MachineClient.describe(error), isRefusal: false)
            return
        }
        while !isClosed {
            do {
                switch try await task.receive() {
                case .data(let data): continuation.yield(.output(data))
                case .string(let text): continuation.yield(.output(Data(text.utf8)))
                @unknown default: break
                }
            } catch {
                let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
                finish(reason: reason?.isEmpty == false ? reason : MachineClient.describe(error), isRefusal: task.closeCode == .policyViolation)
                return
            }
        }
    }

    public func send(_ bytes: Data) async {
        guard !isClosed else { return }
        try? await task.send(.data(bytes))
    }

    public func resize(columns: Int, rows: Int) async {
        guard !isClosed, columns > 0, rows > 0 else { return }
        try? await task.send(.string(Self.text(.resize(columns: columns, rows: rows))))
    }

    /// Hands the socket a fresh token before the one it opened with runs out.
    public func reauthenticate(token: String) async {
        guard !isClosed else { return }
        try? await task.send(.string(Self.text(.reauth(token: token))))
    }

    public func close() {
        guard !isClosed else { return }
        task.cancel(with: .normalClosure, reason: nil)
        finish(reason: nil, isRefusal: false)
    }

    private func finish(reason: String?, isRefusal: Bool) {
        guard !isClosed else { return }
        isClosed = true
        continuation.yield(.closed(reason: reason, isRefusal: isRefusal))
        continuation.finish()
    }
}

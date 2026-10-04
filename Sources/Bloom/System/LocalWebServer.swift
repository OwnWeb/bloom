import Foundation
import Network

/// A loopback-only HTTP listener for Bloom's optional browser client. Tailscale Serve can proxy
/// this port later without making Bloom listen on a public interface.
final class LocalWebServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data

        var path: String { String(target.prefix(while: { $0 != "?" })) }
    }

    struct Response: Sendable {
        let status: Int
        let contentType: String
        let body: Data
        let contentSecurityPolicy: String?

        init(
            _ status: Int = 200, contentType: String = "application/json; charset=utf-8",
            body: Data, contentSecurityPolicy: String? = nil
        ) {
            self.status = status
            self.contentType = contentType
            self.body = body
            self.contentSecurityPolicy = contentSecurityPolicy
        }

        static func text(_ status: Int, _ message: String) -> Self {
            Response(status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
        }

        var bytes: Data {
            let reason: String = switch status {
            case 200: "OK"
            case 202: "Accepted"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 404: "Not Found"
            case 405: "Method Not Allowed"
            case 413: "Content Too Large"
            case 503: "Service Unavailable"
            default: "Internal Server Error"
            }
            var headers = [
                "HTTP/1.1 \(status) \(reason)",
                "Content-Type: \(contentType)",
                "Content-Length: \(body.count)",
                "Cache-Control: no-store",
                "X-Content-Type-Options: nosniff",
                "Referrer-Policy: no-referrer",
                "Connection: close",
            ]
            if let contentSecurityPolicy { headers.append("Content-Security-Policy: \(contentSecurityPolicy)") }
            let head = (headers + ["", ""]).joined(separator: "\r\n")
            return Data(head.utf8) + body
        }
    }

    private enum Parsed {
        case waiting
        case invalid(Int)
        case ready(Request)
    }

    private static let maximumRequestBytes = 64 * 1_024
    private let listener: NWListener
    private let queue = DispatchQueue(label: "be.spatie.bloom.local-web", qos: .userInitiated)
    private let handler: @Sendable (Request) async -> Response
    private let onReady: @Sendable (UInt16) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(
        handler: @escaping @Sendable (Request) async -> Response,
        onReady: @escaping @Sendable (UInt16) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
        self.onReady = onReady
        self.onFailure = onFailure
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port { self.onReady(port.rawValue) }
            case .failed(let error):
                self.onFailure(error.localizedDescription)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.read(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumRequestBytes) { [weak self] chunk, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            let bytes = accumulated + (chunk ?? Data())
            guard error == nil, bytes.count <= Self.maximumRequestBytes else {
                self.send(.text(413, "Request too large"), on: connection)
                return
            }
            switch Self.parse(bytes) {
            case .waiting where !complete:
                self.read(connection, accumulated: bytes)
            case .waiting, .invalid:
                self.send(.text(400, "Bad request"), on: connection)
            case .ready(let request):
                Task { self.send(await self.handler(request), on: connection) }
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        connection.send(content: response.bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parse(_ bytes: Data) -> Parsed {
        let divider = Data("\r\n\r\n".utf8)
        guard let boundary = bytes.range(of: divider) else { return .waiting }
        guard let head = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { return .invalid(400) }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid(400) }
        let parts = first.split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1", parts[1].first == "/",
              parts[0] == "GET" || parts[0] == "POST" else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { return .invalid(400) }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"),
              length >= 0, length <= maximumRequestBytes else { return .invalid(400) }
        let bodyStart = boundary.upperBound
        guard bytes.count - bodyStart >= length else { return .waiting }
        return .ready(Request(
            method: String(parts[0]), target: String(parts[1]), headers: headers,
            body: bytes[bodyStart..<(bodyStart + length)]
        ))
    }
}

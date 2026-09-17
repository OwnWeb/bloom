import BloomCore
import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// A Sprite, held awake through the Tasks API on its management socket.
///
/// **A short task, refreshed, rather than a long one.** A task lives at most an hour, and a server
/// that crashed holding one would keep the machine billing until it expired, so the hold asks for
/// a few minutes and the awake controller renews it well before they run out. If bloom-server dies
/// the machine is free again within minutes.
///
/// Measured before this was written: the service's own user reaches `/.sprite/api.sock`, and a
/// held task kept a Sprite running for 150 seconds with nothing connected. See
/// docs/REMOTE-WORKSPACES.md, "Verified on a real Sprite".
public struct SpriteMachineHost: MachineHost {
    public static let socketPath = "/.sprite/api.sock"
    static let taskName = "bloom-server"

    private let http: HTTPClient
    private let socketPath: String

    public init(http: HTTPClient, socketPath: String = SpriteMachineHost.socketPath) {
        self.http = http
        self.socketPath = socketPath
    }

    /// Whether this process is inside a Sprite at all.
    public static var isAvailable: Bool { FileManager.default.fileExists(atPath: socketPath) }

    public func hold(for duration: Duration) async throws {
        let seconds = max(60, min(3_600, Int(duration.components.seconds)))
        var request = try request(path: "/v1/tasks/\(Self.taskName)", method: .PUT)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(string: #"{"expire": \#(seconds)}"#))
        let response = try await http.execute(request, timeout: .seconds(5))
        guard (200..<300).contains(Int(response.status.code)) else {
            throw SpriteTaskError(status: Int(response.status.code))
        }
    }

    public func release() async throws {
        let request = try request(path: "/v1/tasks/\(Self.taskName)", method: .DELETE)
        let response = try await http.execute(request, timeout: .seconds(5))
        // A task that already expired is released.
        guard (200..<300).contains(Int(response.status.code)) || response.status == .notFound else {
            throw SpriteTaskError(status: Int(response.status.code))
        }
    }

    public func usageSample() -> MachineUsageReading? { LinuxProcReader.sample() }

    private func request(path: String, method: HTTPMethod) throws -> HTTPClientRequest {
        guard let url = URL(httpURLWithSocketPath: socketPath, uri: path) else { throw SpriteTaskError(status: 0) }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method
        // The socket answers on the virtual host `sprite`, which is what `sprite-env curl` sends.
        request.headers.replaceOrAdd(name: "Host", value: "sprite")
        return request
    }
}

struct SpriteTaskError: Error, CustomStringConvertible {
    let status: Int
    var description: String { "The machine's task API answered \(status)." }
}

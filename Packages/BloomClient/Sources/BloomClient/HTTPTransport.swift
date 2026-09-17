import Foundation

/// The one door every request in this package goes through, so a test can stand in for
/// runbloom.app or a machine without a socket.
///
/// Two calls rather than one, because an event stream is read a line at a time for as long as it
/// stays open and a command is read whole: making the second a special case of the first would
/// either buffer a stream that never ends or hand every command a stream to drain.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Opens a streaming response. The lines are handed on as they arrive, without their line
    /// endings, and the sequence ends when the server closes the response.
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
}

/// The transport the app uses.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A session for talking to machines: no cookies, because control never reads them and a
    /// preview cookie must never ride along on a command, and no cache.
    public static func machine() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A stream stays open for as long as the workspace does; a quiet one is not a dead one,
        // since the server's keep-alives come every thirty seconds.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    // `AsyncLineSequence` drops empty lines, and an empty line is what ends an
                    // event in server-sent events, so lines are split here by hand.
                    var line = [UInt8]()
                    for try await byte in bytes {
                        if byte == 0x0A {
                            if line.last == 0x0D { line.removeLast() }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}

import BloomProtocol
import Foundation

/// HTTP to one machine: a command, the event stream, and a fresh token for a stream. No state and
/// no retries; `WorkspaceConnection` decides those.
public struct MachineClient: Sendable {
    let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport.machine()) {
        self.transport = transport
    }

    /// Sends one command.
    ///
    /// - Parameter timeout: how long to wait for an answer. A client allows at least ten seconds
    ///   for the first request to a sleeping machine, because that request is what wakes it: the
    ///   first one after a pause measured 4.5 s end to end.
    public func send(_ command: CommandRequest, to machine: URL, token: String, timeout: TimeInterval) async throws(MachineFailure) -> CommandReply {
        var request = URLRequest(url: machine.appending(path: "_bloom/v1/rpc"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try WireJSON.encode(command)
        } catch {
            throw .unreadable("The command could not be encoded.")
        }
        let (data, response) = try await answer(request)
        switch response.statusCode {
        case 200:
            do {
                let reply = try WireJSON.decode(CommandReply.self, from: data)
                guard reply.commandID == command.commandID else { throw MachineFailure.unreadable("The reply named another command.") }
                return reply
            } catch let failure as MachineFailure {
                throw failure
            } catch {
                throw .unreadable("Check for an update to Bloom.")
            }
        case 401: throw .unauthenticated(Self.failure(data, fallback: WireError(.unauthenticated, "Your access to this Cloud workspace was refused.")))
        case 502, 503, 504: throw .noAnswer("It may still be waking up.")
        default: throw .refused(status: response.statusCode, error: Self.failure(data, fallback: WireError(.internal, "The Cloud workspace refused the request (HTTP \(response.statusCode)).")))
        }
    }

    /// Opens the event stream, resuming after `cursor` when there is one.
    ///
    /// Answers the stream's id, which a fresh token is sent to, and its events. Events this client
    /// cannot decode are skipped, as the protocol asks of an unknown kind; the cursor of a message
    /// event is still reported, so a reconnect does not ask for it again.
    public func events(from machine: URL, token: String, after cursor: Int64?, timeout: TimeInterval) async throws(MachineFailure) -> (streamID: String?, events: AsyncThrowingStream<StreamItem, any Error>) {
        var request = URLRequest(url: machine.appending(path: "_bloom/v1/events"))
        request.timeoutInterval = timeout
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let cursor { request.setValue(String(cursor), forHTTPHeaderField: "Last-Event-ID") }
        let response: HTTPURLResponse
        let lines: AsyncThrowingStream<String, any Error>
        do {
            (response, lines) = try await transport.lines(for: request)
        } catch {
            throw .noAnswer(Self.describe(error))
        }
        guard response.statusCode == 200 else {
            var body = Data()
            do {
                for try await line in lines {
                    body.append(Data(line.utf8))
                    if body.count > 65_536 { break }
                }
            } catch {}
            let fallback = WireError(.internal, "The Cloud workspace refused its event stream (HTTP \(response.statusCode)).")
            if response.statusCode == 401 { throw .unauthenticated(Self.failure(body, fallback: fallback)) }
            if [502, 503, 504].contains(response.statusCode) { throw .noAnswer("It may still be waking up.") }
            throw .refused(status: response.statusCode, error: Self.failure(body, fallback: fallback))
        }
        let streamID = response.value(forHTTPHeaderField: "Bloom-Stream-ID")
        let items = AsyncThrowingStream<StreamItem, any Error> { continuation in
            let task = Task {
                var parser = ServerSentEvents()
                do {
                    for try await line in lines {
                        guard let frame = parser.feed(line) else { continue }
                        continuation.yield(Self.item(frame))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (streamID, items)
    }

    /// Hands an open stream a fresh token. `true` when it took.
    public func refresh(stream id: String, on machine: URL, token: String) async -> Bool {
        var request = URLRequest(url: machine.appending(path: "_bloom/v1/streams/\(id)/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await transport.data(for: request) else { return false }
        return (200..<300).contains(response.statusCode)
    }

    /// One frame off the stream, decoded when it can be.
    public enum StreamItem: Sendable, Hashable {
        case event(WorkspaceEvent)
        /// A frame of a kind this client does not know, kept only for its cursor.
        case skipped(cursor: Int64?)
    }

    static func item(_ frame: ServerSentEvents.Event) -> StreamItem {
        if let event = try? WireJSON.decode(WorkspaceEvent.self, from: Data(frame.data.utf8)) {
            return .event(event)
        }
        return .skipped(cursor: frame.id.flatMap { Int64($0) })
    }

    private func answer(_ request: URLRequest) async throws(MachineFailure) -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch {
            throw .noAnswer(Self.describe(error))
        }
    }

    static func failure(_ data: Data, fallback: WireError) -> WireError {
        (try? WireJSON.decode(WireError.self, from: data)) ?? fallback
    }

    static func describe(_ error: any Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "It took too long to answer."
            case .notConnectedToInternet: return "This Mac is offline."
            case .cannotFindHost, .dnsLookupFailed: return "Its address could not be found."
            case .networkConnectionLost: return "The connection dropped."
            case .cancelled: return "The request was cancelled."
            default: return url.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

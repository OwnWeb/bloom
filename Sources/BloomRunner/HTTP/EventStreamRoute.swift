import BloomCore
import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird

/// `GET /_bloom/v1/events`: server-sent events, read with `fetch` so the token can travel in a
/// header, and `POST /_bloom/v1/streams/{id}/token` to renew one.
///
/// The stream's id comes back in a response header rather than in the stream, so a client has it
/// before the first event. `Last-Event-ID` is a transcript cursor: see `WorkspaceEvent`.
enum EventStreamRoute {
    static let streamIDHeader = HTTPField.Name("Bloom-Stream-ID")!
    static let lastEventIDHeader = HTTPField.Name("Last-Event-ID")!
    /// Which kind of client is opening the stream: `mac` for Bloom on a Mac. See `RemoteEventHub`.
    static let clientHeader = HTTPField.Name("Bloom-Client")!
    /// A comment line now and then, so a proxy that closes quiet connections does not. Measured:
    /// the machine's own URL held a stream with 100 seconds of silence, and 25 is well inside that.
    static let keepAliveInterval: Duration = .seconds(25)

    static func register(on router: Router<WorkspaceRequestContext>, runtime: WorkspaceRuntime, verifier: TokenVerifier, streams: EventStreams) {
        router.get("/_bloom/v1/events") { request, _ -> Response in
            let token: WorkspaceToken
            do {
                token = try await verifier.verify(request.bearerToken ?? "", as: .session)
                guard token.abilities.contains("view") else { throw RemoteFailure(.missingAbility, "Your access does not include viewing this workspace.") }
                try token.refuseIfMintedForAnAgent()
            } catch {
                return WireResponses.failure(error)
            }
            let cursor = request.headers[lastEventIDHeader].flatMap { Int64($0) }
            // Counted before the runtime subscribes, so a person over the cap costs nothing.
            let id: String, closing: AsyncStream<WireError>
            do {
                (id, closing) = try await streams.open(for: token)
            } catch {
                return WireResponses.failure(error)
            }
            let events: AsyncStream<WorkspaceEvent>
            do {
                events = try await runtime.openEvents(for: token.caller(token: request.bearerToken ?? ""), after: cursor,
                                                      client: request.headers[clientHeader])
            } catch {
                await streams.closed(id)
                return WireResponses.failure(error)
            }
            // A revoke that landed while the stream was being opened found nothing to close.
            if await verifier.revocations.isRevoked(token.subject, issuedAt: token.issuedAt) {
                await streams.closed(id)
                return WireResponses.failure(RemoteFailure(.unauthenticated, "Your access to this Bloom Cloud workspace was removed."))
            }
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-store"
            headers[streamIDHeader] = id
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in
                defer { Task { await streams.closed(id) } }
                let merged = merge(events: events, closing: closing)
                for await frame in merged {
                    try await writer.write(ByteBuffer(string: frame))
                }
                try await writer.finish(nil)
            })
        }

        router.post("/_bloom/v1/streams/:id/token") { request, context -> Response in
            guard let id = context.parameters.get("id") else { return Response(status: .notFound) }
            do {
                let token = try await verifier.verify(request.bearerToken ?? "", as: .session)
                // Checked again on renewal, so somebody whose access narrowed cannot keep watching
                // on fresh tokens that no longer allow it.
                guard token.abilities.contains("view") else {
                    throw RemoteFailure(.missingAbility, "Your access does not include viewing this workspace.")
                }
                try token.refuseIfMintedForAnAgent()
                try await streams.refresh(id, with: token)
                return Response(status: .noContent)
            } catch {
                return WireResponses.failure(error)
            }
        }
    }

    /// How many frames wait for a client that is not reading before its stream is ended. The
    /// hub's own bound, so the layer above it cannot hold more than the layer it drains.
    static let bufferLimit = RemoteEventHub.defaultBufferLimit

    /// The runtime's events, the stream's own reasons to close, and a keep-alive, as SSE frames.
    ///
    /// **Bounded, and a reader that falls behind is let go.** This stream used to buffer without
    /// limit, and its pump drained the bounded streams under it as fast as they filled, so their
    /// overflow never fired and a client that stopped reading grew the machine's memory; the review
    /// of 19 September 2026 found it as M3. Now a frame that does not fit ends the stream, and the
    /// client reconnects with `Last-Event-ID` and is replayed what it missed.
    static func merge(events: AsyncStream<WorkspaceEvent>, closing: AsyncStream<WireError>,
                      bufferLimit: Int = bufferLimit, dropped: (@Sendable () -> Void)? = nil) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingOldest(bufferLimit)) { continuation in
            let send: @Sendable (String) -> Bool = { text in
                if case .dropped = continuation.yield(text) {
                    dropped?()
                    continuation.finish()
                    return false
                }
                return true
            }
            let pump = Task {
                for await event in events {
                    guard send(frame(event)) else { return }
                    if case .sleeping = event { break }
                    if case .closing = event { break }
                }
                continuation.finish()
            }
            let closer = Task {
                for await reason in closing {
                    _ = send(frame(.closing(reason)))
                    continuation.finish()
                    return
                }
            }
            let keepAlive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: keepAliveInterval)
                    if Task.isCancelled { return }
                    guard send(": keep-alive\n\n") else { return }
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                closer.cancel()
                keepAlive.cancel()
            }
        }
    }

    /// One event as SSE: `event:` its kind, `id:` its cursor when it has one, `data:` its JSON on a
    /// single line, which the JSON encoder guarantees because it escapes every newline.
    static func frame(_ event: WorkspaceEvent) -> String {
        let data = (try? WireJSON.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var text = "event: \(event.kind)\n"
        if let cursor = event.cursor { text += "id: \(cursor)\n" }
        text += "data: \(data)\n\n"
        return text
    }
}

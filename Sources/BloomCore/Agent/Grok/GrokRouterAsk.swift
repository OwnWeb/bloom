import Foundation

/// The routing question asked of Grok: one session, one prompt, on a short-lived ACP connection.
///
/// Not the headless print mode, whose only answer to a permission question is
/// `--always-approve`. ACP has no system prompt and no "no tools" switch, so the session runs in
/// plan mode in a scratch directory with every permission refused; Grok may still read a file
/// without asking.
public enum GrokRouterAsk {
    public typealias MakeClient = @Sendable (GrokClient.Configuration) -> GrokClient

    public static let liveClient: MakeClient = { GrokClient(configuration: $0) }

    public static func ask(_ request: ModelRouterRequest, makeClient: @escaping MakeClient = GrokRouterAsk.liveClient) -> AsyncThrowingStream<RouterSignal, Error> {
        AsyncThrowingStream { continuation in
            let client = makeClient(GrokClient.Configuration(
                executable: request.executable,
                cwd: request.cwd,
                model: request.analyser.model,
                effort: request.analyser.effort,
                alwaysApprove: false
            ))
            let worker = Task {
                // Subscribed before `start`, because the fan-out replays nothing to a late reader.
                let events = client.events
                do {
                    try await client.start()
                    let session = try await client.newSession(
                        cwd: request.cwd,
                        mcpServers: [],
                        permissionMode: .plan
                    )
                    let promptID = try await client.beginPrompt(
                        sessionID: session.id,
                        text: GrokRouterAsk.prompt(for: request)
                    )
                    var decoder = Decoder(session: session.id, promptID: promptID)
                    for await event in events {
                        if case .permission(let asked) = event {
                            await client.answer(asked.id, with: GrokPermission.cancelledResult)
                            continue
                        }
                        for signal in decoder.signals(for: event) { continuation.yield(signal) }
                        if decoder.isFinished { break }
                    }
                    if !decoder.isFinished { continuation.yield(.finished(isError: true)) }
                    await client.closeSession(session.id)
                    await client.stop()
                    continuation.finish()
                } catch {
                    await client.stop()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
                Task { await client.stop() }
            }
        }
    }

    /// The instructions and the task in one message, since ACP has nowhere else to put the first.
    static func prompt(for request: ModelRouterRequest) -> String {
        request.systemPrompt + "\n\n" + request.prompt
    }

    /// Grok has no "message finished" event, so `ModelRouterProgress` joins the chunks, and the
    /// prompt's reply ends the turn.
    struct Decoder {
        /// Grok's own session id, not a Bloom id.
        let session: String
        let promptID: GrokRequestID
        private(set) var isFinished = false

        init(session: String, promptID: GrokRequestID) {
            self.session = session
            self.promptID = promptID
        }

        mutating func signals(for event: GrokEvent) -> [RouterSignal] {
            switch event {
            case .update(let update):
                guard update.sessionID.isEmpty || update.sessionID == session else { return [] }
                switch update.kind {
                case .thought(let chunk): return chunk.isEmpty ? [] : [.thinking(chunk)]
                case .text(let chunk): return chunk.isEmpty ? [] : [.text(chunk)]
                case .toolCall, .toolCallUpdate, .usage, .other: return []
                }
            case .promptCompleted(let result):
                guard result.requestID == promptID else { return [] }
                isFinished = true
                return [.finished(isError: result.isError || result.wasCancelled)]
            case .closed:
                isFinished = true
                return [.finished(isError: true)]
            case .sessionReady, .permission, .unknown:
                return []
            }
        }
    }
}

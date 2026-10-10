import Foundation

/// The routing question asked of Grok: one session, one prompt, on a short-lived ACP connection.
///
/// **ACP rather than the headless print mode.** `docs/GROK.md` calls `--output-format
/// streaming-messages-json` a trap for a chat, because it is one prompt and then exit. One prompt
/// and then exit is exactly what this is, but that mode has no answer for a permission question
/// other than `--always-approve`, and an analyser must never be allowed to approve anything. The
/// connection is the one `GrokModelCatalog.live` already opens and closes for a single question.
///
/// **What it can and cannot promise.** ACP has no system prompt and no switch for "no tools", and
/// Grok loads the owner's own MCP servers whatever the session is given. So the session is in plan
/// mode, in an empty scratch directory, every permission it asks for is refused, and the
/// instructions travel at the head of the prompt. Plan is the strictest mode `PermissionMode` can
/// send, and it is a research mode: Grok may still read a file without asking, which is less than
/// `ClaudeRouterAsk` promises and more than nothing. The router's settings say so.
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

    /// ACP updates in, signals out, for the one session and the one prompt this call made.
    ///
    /// Grok has no "message finished" event, so the answer arrives as the chunks themselves and
    /// `ModelRouterProgress` joins them. The prompt's reply is the end of the turn.
    struct Decoder {
        /// Grok's own session, as ACP names it. Not a Bloom id, so not one of Bloom's id types.
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

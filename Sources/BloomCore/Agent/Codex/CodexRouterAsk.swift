import Foundation

/// The routing question asked of Codex: one thread, one turn, on a short-lived app-server
/// (`codex exec` has no reasoning deltas for the card to draw).
///
/// Codex has no "no tools" switch, so the thread is read-only in a scratch directory on the
/// `untrusted` policy and every approval is declined. Not `never`: a read-only sandbox runs reads
/// without asking, so `never` let the analyser `cat` any file by absolute path. No output schema
/// is sent; the prompt asks for the JSON in words.
public enum CodexRouterAsk {
    public typealias MakeClient = @Sendable (CodexClient.Configuration) -> CodexClient

    public static let liveClient: MakeClient = { CodexClient(configuration: $0) }

    /// `turn/start` spells it `readOnly`; `thread/start` takes `read-only`.
    static let readOnlyPolicy = JSONValue.object(["type": .string("readOnly")])

    public static func ask(_ request: ModelRouterRequest, makeClient: @escaping MakeClient = CodexRouterAsk.liveClient) -> AsyncThrowingStream<RouterSignal, Error> {
        AsyncThrowingStream { continuation in
            let client = makeClient(CodexClient.Configuration(executable: request.executable, cwd: request.cwd))
            let worker = Task {
                // Subscribed before `start`, because the fan-out replays nothing to a late reader.
                let events = client.events
                let model = request.analyser.model.isEmpty ? nil : request.analyser.model
                do {
                    try await client.start()
                    let thread = try await client.startThread(
                        cwd: request.cwd,
                        model: model,
                        approvalPolicy: .untrusted,
                        sandbox: .readOnly,
                        developerInstructions: request.systemPrompt
                    )
                    try await client.startTurn(
                        threadID: thread.id,
                        input: [.text(request.prompt)],
                        model: model,
                        effort: request.analyser.effort,
                        approvalPolicy: .untrusted,
                        sandboxPolicy: CodexRouterAsk.readOnlyPolicy
                    )
                    var decoder = Decoder(threadID: thread.id)
                    for await event in events {
                        if case .approval(let asked) = event {
                            await client.answer(asked, decision: .decline)
                            continue
                        }
                        for signal in decoder.signals(for: event) { continuation.yield(signal) }
                        if decoder.isFinished { break }
                    }
                    // No turn end means cancellation (deadline or Skip), reported as an error so nothing reads
                    // a half answer as whole.
                    if !decoder.isFinished { continuation.yield(.finished(isError: true)) }
                    await client.stop()
                    continuation.finish()
                } catch {
                    await client.stop()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
                // A request awaiting its reply does not hear the cancel, so close the connection too.
                Task { await client.stop() }
            }
        }
    }

    /// The answer's text comes from finished `agentMessage` items rather than deltas, so it arrives
    /// once. Only `.commentary` is skipped, because providers set the phase inconsistently.
    struct Decoder {
        let threadID: String
        private(set) var isFinished = false
        private var reasoningItem: String?
        private var streamedReasoning = false
        private var sawAnswer = false

        init(threadID: String) {
            self.threadID = threadID
        }

        mutating func signals(for event: CodexEvent) -> [RouterSignal] {
            if let id = event.threadID, !id.isEmpty, id != threadID { return [] }
            switch event {
            case .reasoningDelta(let delta):
                guard !delta.text.isEmpty else { return [] }
                let breaks = reasoningItem != nil && reasoningItem != delta.itemID
                reasoningItem = delta.itemID
                streamedReasoning = true
                return [.thinking(breaks ? "\n\n" + delta.text : delta.text)]
            case .itemCompleted(let completed):
                return signals(for: completed.item)
            case .turnCompleted(let turn):
                isFinished = true
                // Some servers send the last item only in the turn's completion.
                let late = sawAnswer ? [] : turn.items.flatMap { signals(for: $0) }
                return late + [.finished(isError: turn.status == .failed)]
            case .turnError(let failure):
                guard !failure.willRetry else { return [] }
                isFinished = true
                return [.finished(isError: true)]
            case .closed:
                isFinished = true
                return [.finished(isError: true)]
            default:
                return []
            }
        }

        private mutating func signals(for item: CodexItem) -> [RouterSignal] {
            switch item {
            case .agentMessage(let message):
                guard message.phase != .commentary, !message.text.isEmpty else { return [] }
                sawAnswer = true
                return [.text(message.text)]
            case .reasoning(let reasoning):
                guard !streamedReasoning, !reasoning.displayText.isEmpty else { return [] }
                return [.thinking(reasoning.displayText)]
            default:
                return []
            }
        }
    }
}

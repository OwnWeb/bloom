import Foundation

/// The routing question asked of Codex: one thread, one turn, on a short-lived app-server.
///
/// **The app-server, not `codex exec`.** `docs/CODEX.md` says why Bloom never drives `exec`, and
/// one of its reasons is the one this needs: `exec` has no reasoning deltas, so the card would have
/// nothing to draw under its spinner. The connection is the one `CodexSpeed.read` and the model
/// catalogue already open for a single question and close behind them.
///
/// **What it can and cannot promise.** Unlike Claude Code, Codex has no switch for "no tools at
/// all", and the owner's own MCP servers start with it. So the thread is read-only, in an empty
/// scratch directory, and on the `untrusted` approval policy, which asks about nearly every command
/// including reads (see `CodexRunner.approvalPolicy`); every question it asks is declined. Not
/// `never`, which was this file's first answer and the wrong one: `docs/CODEX.md` measured that a
/// read-only sandbox runs reads and commands without a single question, so `never` let the
/// analyser `cat` any file the owner can read, by absolute path, whatever folder it stood in. That
/// is still less than `ClaudeRouterAsk` promises, and the router's settings say so.
///
/// No output schema is sent, because the typed `turn/start` has none and nothing in this tree has
/// measured whether the server takes one. The prompt asks for the JSON in words, and
/// `ModelRouterProgress` reads it out of the answer's text.
public enum CodexRouterAsk {
    public typealias MakeClient = @Sendable (CodexClient.Configuration) -> CodexClient

    public static let liveClient: MakeClient = { CodexClient(configuration: $0) }

    /// The turn's sandbox, as `turn/start` spells it. `thread/start` takes the kebab-case
    /// `read-only` instead; see `CodexClient.startThread`.
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
                    // The stream ended without a turn ending, which is cancellation: the deadline
                    // or Skip. Said as an error so nothing reads a half answer as a whole one.
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
                // A request waiting on its reply does not hear the cancel, so the connection is
                // closed under it as well. `stop` is single shot, so a second one is harmless.
                Task { await client.stop() }
            }
        }
    }

    /// Codex events in, signals out, for the one thread this call opened.
    ///
    /// Reasoning is passed on as it streams. The answer's text is taken from the finished
    /// `agentMessage` items rather than from their deltas, so it arrives once; narration a model
    /// writes before its answer is left out, and `.unknown` is not, because the schema warns that
    /// providers do not set the phase consistently.
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
                // A turn whose answer only arrived in its completion, which is how some servers
                // send the last item.
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

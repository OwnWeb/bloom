import Foundation

/// One client looking at one terminal, as a tmux control mode client.
///
/// What a WebSocket handler drives: bytes out through `output`, keystrokes in through `write`,
/// and `resize` and `close`. Closing ends only this control client. The shell in the tmux session
/// keeps running, and the next attachment redraws its screen and cursor from tmux's own copy,
/// so a client that reconnects sees what it left rather than a blank terminal.
///
/// `output` is bounded. A client that stops reading while a command floods the terminal would
/// otherwise grow this buffer without limit, and dropping bytes from the middle would leave the
/// screen wrong in a way nothing repairs. So an overflowing attachment closes itself instead, and
/// the client's reconnect gets a clean redraw.
public actor RemoteTerminalAttachment {
    public nonisolated let name: String
    public nonisolated let output: AsyncStream<Data>
    private let session: String
    private let process: StreamingProcess
    private let continuation: AsyncStream<Data>.Continuation
    private let onClose: @Sendable () async -> Void
    private var reader: Task<Void, Never>?
    private var ending: Task<Void, Never>?

    static let outputBufferChunks = 4_096

    init(name: String, session: String, process: StreamingProcess, onClose: @escaping @Sendable () async -> Void) {
        self.name = name
        self.session = session
        self.process = process
        self.onClose = onClose
        (output, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(Self.outputBufferChunks))
    }

    /// Starts the control client and asks for the screen as it stands. The four commands are the
    /// four reply blocks `TmuxControlOutput` counts, in order, so the size is clamped rather than
    /// refused: a refused resize would be a missing block and a screen restored from the wrong one.
    func start(columns: Int, rows: Int) {
        let lines = process.lines
        let columns = min(max(columns, 2), 500)
        let rows = min(max(rows, 2), 300)
        process.writeLine("refresh-client -C \(columns),\(rows)")
        process.writeLine("capture-pane -p -e -t =" + session + ":")
        process.writeLine("display-message -p -t =" + session + ": '#{cursor_x} #{cursor_y}'")
        continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { await self?.close() }
        }
        reader = Task { [weak self, continuation] in
            var decoder = TmuxControlOutput(restoringScreen: true)
            do {
                for try await line in lines {
                    guard let data = decoder.take(line) else { continue }
                    if case .dropped = continuation.yield(data) { break }
                }
            } catch {
                // A control client that fails ends the same way as one that exits: the stream
                // finishes and the client reconnects.
            }
            await self?.readerFinished()
        }
    }

    public func write(_ data: Data) {
        guard ending == nil else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset + TmuxControlOutput.inputLimit, data.count)
            if let command = TmuxControlOutput.input(data.subdata(in: offset..<end), session: session) {
                process.writeLine(command)
            }
            offset = end
        }
    }

    public func resize(columns: Int, rows: Int) {
        guard ending == nil, let command = TmuxControlOutput.resize(columns: columns, rows: rows) else { return }
        process.writeLine(command)
    }

    /// Ends the control client and waits until it has exited. Safe to call more than once.
    public func close() async {
        await beginClose().value
        await reader?.value
    }

    private func readerFinished() {
        _ = beginClose()
    }

    /// Never waits on the reader, because the reader's own last step is to come here.
    private func beginClose() -> Task<Void, Never> {
        if let ending { return ending }
        let stopping = RemoteTerminalProcessLifetime.stop(process)
        reader?.cancel()
        let task = Task { [continuation, onClose] in
            await stopping.value
            continuation.finish()
            await onClose()
        }
        ending = task
        return task
    }
}

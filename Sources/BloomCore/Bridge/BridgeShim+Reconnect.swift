import Foundation
import Synchronization

extension BridgeShim {
    static func runReconnecting(configurationPath: String, shim: String?) async -> Int32 {
        let input = ReconnectInput()
        return await withTaskCancellationHandler {
            defer { input.stop() }
            input.start()
            // Fresh connections recover after restart without replaying calls that may have changed data.
            for await line in input.lines {
                guard !input.isStopped else { break }
                guard let id = MCPRequest.decode(line)?.replyID else { continue }
                let reply = await reconnectReply(
                    to: line, id: id, configurationPath: configurationPath, shim: shim, input: input
                )
                guard !input.isStopped else { break }
                write(reply + "\n", to: STDOUT_FILENO)
            }
            return Exit.ok
        } onCancel: {
            input.stop()
        }
    }

    private static func reconnectReply(
        to line: String, id: JSONValue, configurationPath: String, shim: String?, input: ReconnectInput
    ) async -> String {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
            let config = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let environment = config["mcpServers"]?[BridgeRegistration.serverName]?["env"],
                  let socket = environment[BridgeProtocol.socketVariable]?.stringValue,
                  let token = environment[BridgeProtocol.tokenVariable]?.stringValue else {
                throw ReconnectFailure("Bloom's bridge configuration is unavailable.")
            }
            let connection = try UnixSocketConnection.connect(to: socket)
            input.use(connection)
            defer { input.disconnect() }
            var replies = connection.lines.makeAsyncIterator()
            let hello = BridgeHello(
                token: token,
                role: environment[BridgeProtocol.roleVariable]?.stringValue ?? BridgeRole.workspace.rawValue,
                shim: shim
            )
            connection.writeLine(String(decoding: try JSONEncoder().encode(hello), as: UTF8.self))
            guard let welcomeLine = await replies.next() else {
                throw ReconnectFailure("Bloom disconnected before accepting the bridge.")
            }
            let welcome = try JSONDecoder().decode(BridgeWelcome.self, from: Data(welcomeLine.utf8))
            guard welcome.accepted else {
                throw ReconnectFailure(welcome.problem ?? "Bloom refused the bridge connection.")
            }
            connection.writeLine(line)
            guard let reply = await replies.next() else {
                throw ReconnectFailure("Bloom disconnected before answering. The call was not retried.")
            }
            return reply
        } catch {
            return MCPResponse.failure(
                id: id, code: MCPErrorCode.internalError,
                message: "\(error.readableMessage) Reopen Bloom before trying another call."
            ).line()
        }
    }

    private struct ReconnectFailure: LocalizedError {
        let errorDescription: String?

        init(_ message: String) { errorDescription = message }
    }

    private final class ReconnectInput: Sendable {
        private struct State {
            var stopped = false
            var connection: UnixSocketConnection?
        }

        private let state = Mutex(State())
        private let buffer = LineBuffer()
        let lines: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation

        init() {
            (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        }

        var isStopped: Bool { state.withLock { $0.stopped } }

        func start() {
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else {
                    stop()
                    return
                }
                for line in buffer.take(data) { continuation.yield(line) }
            }
            if isStopped { FileHandle.standardInput.readabilityHandler = nil }
        }

        func use(_ connection: UnixSocketConnection) {
            let stopped = state.withLock { state in
                if !state.stopped { state.connection = connection }
                return state.stopped
            }
            if stopped { connection.close() }
        }

        func disconnect() {
            let connection = state.withLock { state in
                let connection = state.connection
                state.connection = nil
                return connection
            }
            connection?.close()
        }

        func stop() {
            state.withLock { $0.stopped = true }
            FileHandle.standardInput.readabilityHandler = nil
            disconnect()
            continuation.finish()
        }
    }
}

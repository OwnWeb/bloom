import Foundation
import Hummingbird
import Logging
import NIOCore
import Synchronization
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Scratch space, shell commands and a local HTTP listener for the setup, services and Caddy tests.
enum SetupTestSupport {
    static func directory(_ label: String) throws -> String {
        let path = NSTemporaryDirectory() + "bloom-\(label)-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        // Resolved, because a Mac's temporary directory is behind `/var` -> `/private/var` and git
        // reports the resolved path.
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    struct CommandFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs a bash command and returns its output, throwing when it fails.
    @discardableResult
    static func bash(_ command: String, in directory: String? = nil, environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandFailed(description: "\(command) exited \(process.terminationStatus): \(text)")
        }
        return text
    }

    static func write(_ text: String, to path: String, executable: Bool = false) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    }

    static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Polls until the condition holds or the timeout passes, and says whether it held.
    static func eventually(timeout: Duration = .seconds(20), _ condition: @Sendable () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    /// A zombie counts as dead. In CI's container the process that inherits an orphan is one that
    /// never reaps, so a killed child stays in the table as `Z` and `kill(pid, 0)` still succeeds.
    static func isAlive(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")") {
            let state = stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).first
            return state != "Z"
        }
        return true
    }
}

/// A Hummingbird application on 127.0.0.1, run for the length of a test.
final class LocalListener: Sendable {
    private let task: Task<Void, Error>
    let port: Int

    private init(task: Task<Void, Error>, port: Int) {
        self.task = task
        self.port = port
    }

    /// Starts the router on a port the system picks, or on the one given.
    static func start(port: Int = 0, _ build: (Router<BasicRequestContext>) -> Void) async throws -> LocalListener {
        let router = Router()
        build(router)
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        // Cancelling a server in the middle of a connection is how every test ends, and Hummingbird
        // logs each of those as an error.
        var logger = Logger(label: "bloom-test-listener")
        logger.logLevel = .critical
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port)),
            onServerRunning: { channel in
                continuation.yield(channel.localAddress?.port ?? 0)
                continuation.finish()
            },
            logger: logger
        )
        let task = Task { try await app.runService(gracefulShutdownSignals: []) }
        var bound = 0
        for await value in stream {
            bound = value
        }
        return LocalListener(task: task, port: bound)
    }

    func stop() async {
        task.cancel()
        _ = try? await task.value
    }
}

/// A port nothing is listening on at the moment of asking, for a listener that has to be named
/// before it exists.
enum FreePort {
    static func pick() async throws -> Int {
        let listener = try await LocalListener.start { _ in }
        let port = listener.port
        await listener.stop()
        return port
    }
}

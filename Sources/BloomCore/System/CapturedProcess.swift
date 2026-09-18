import Foundation
import Synchronization

/// One worker owns the pipe descriptors, from opening to closing. Nonblocking I/O lets the same
/// deadline cover a blocked stdin writer, a stubborn child, and inherited output after exit.
/// Previously Shell stopped its timer at child exit and could return success minutes later.
final class CapturedProcess: Sendable {
    private let cancelled = Mutex(false)
    private let executable: String
    private let arguments: [String]
    private let cwd: String?
    private let environment: [String: String]
    private let input: Data?
    private let timeout: Duration?
    private let outputLimit: Int
    /// Stands in for the launch and the read loop, so a test can prove the watchdog answers when
    /// the work never does. Nil everywhere but in `CapturedProcessTests`: there is no way to make
    /// a real `Process.run()` hang on demand, and a watchdog nothing exercises is a watchdog that
    /// stops working without anybody noticing.
    private let work: (@Sendable () throws -> ShellBytes)?
    /// The grace, as a value so a test does not have to wait the real fifteen seconds to prove it.
    private let grace: Duration

    init(
        executable: String, arguments: [String], cwd: String?, environment: [String: String],
        input: Data?, timeout: Duration?, outputLimit: Int,
        work: (@Sendable () throws -> ShellBytes)? = nil, grace: Duration = CapturedProcess.launchGrace
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.input = input
        self.timeout = timeout
        self.outputLimit = max(1, outputLimit)
        self.work = work
        self.grace = grace
    }

    /// How long after the caller's own deadline this gives up on the worker thread entirely.
    ///
    /// **A launch that never returns must not stop the machine.** `collect` honours the deadline
    /// itself: it polls with a twenty millisecond timeout and checks the clock on every pass, so
    /// nothing inside it can outlast the timeout by more than that. The launch before it is
    /// Foundation's, and it has no deadline of ours. On a Cloud workspace's first start, one
    /// `git config` child exited within a second, was never reaped, and `Process.run()` never
    /// returned: the machine answered health, RPC and its own shutdown for eighteen minutes while
    /// setup sat in that one call and the workspace was never cloned. No debugger can attach to a
    /// Sprite to say why, so the fix is to stop waiting rather than to wait better.
    ///
    /// The grace is what keeps this a backstop rather than a second timeout: `collect` gets its
    /// full deadline and the chance to kill the child and report properly, and only a call that is
    /// past even that is abandoned. The worker thread is left where it is, because there is nothing
    /// safe to do with a thread parked inside Foundation, and one leaked thread costs a stack where
    /// a machine that never boots costs the whole workspace.
    static let launchGrace: Duration = .seconds(15)

    func run() async throws -> ShellBytes {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let answered = Mutex(false)
                // Whoever gets there first answers; a continuation resumed twice is a crash.
                let finish = { @Sendable (result: Result<ShellBytes, any Error>) in
                    let first = answered.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    continuation.resume(with: result)
                }
                let worker = Thread { [self] in
                    finish(Result { try work?() ?? capture() })
                }
                worker.stackSize = 512 * 1_024
                worker.start()
                // Only when the caller asked for a deadline. A call with no timeout is one whose
                // length nobody here knows, and cutting it off at an invented number would end a
                // long clone or a slow test run for no reason.
                if let timeout {
                    Task { [executable, grace] in
                        try? await Task.sleep(for: timeout + grace)
                        let abandoning = answered.withLock { !$0 }
                        guard abandoning else { return }
                        Shell.countAbandonedLaunch()
                        let line = "bloom: abandoning a launch of \(executable) that never returned; "
                            + "\(Shell.abandonedLaunchCount) so far this run\n"
                        FileHandle.standardError.write(Data(line.utf8))
                        finish(.failure(ShellFailure.timedOut(command: executable)))
                    }
                }
            }
        } onCancel: {
            self.cancelled.withLock { $0 = true }
        }
    }

    private func capture() throws -> ShellBytes {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin

        // The worker is the only reader/writer. Closing in its defer cannot race a readability
        // callback or close a descriptor that another reader has already released and reused.
        let handles = [output.fileHandleForReading, errors.fileHandleForReading, stdin.fileHandleForWriting]
        defer {
            for handle in handles { try? handle.close() }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
        }
        for handle in handles {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw pipeFailure("configure pipes", errno)
            }
        }
        SystemCalls.configurePipeWrites(stdin.fileHandleForWriting.fileDescriptor)

        let started = ContinuousClock.now
        let deadline = timeout.map { started.advanced(by: $0) }
        try ProcessLaunch.run(process)
        Shell.countSpawn()
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid && pid != getpgrp()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()

        do {
            return try collect(
                process: process, handles: handles, deadline: deadline
            )
        } catch {
            // Only this invocation's process/group is signalled. Never kill Bloom's own group
            // when a platform or launcher has kept the child in it.
            stop(process, pid: pid, ownsGroup: ownsGroup)
            throw error
        }
    }

    private func collect(
        process: Process, handles: [FileHandle], deadline: ContinuousClock.Instant?
    ) throws -> ShellBytes {
        var streams = [Data(), Data()]
        var readers = [true, true]
        var inputOffset = 0
        var inputOpen = true
        var exitedAt: ContinuousClock.Instant?
        let bytes = input ?? Data()
        while true {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            let now = ContinuousClock.now
            if let deadline, now >= deadline { throw ShellFailure.timedOut(command: executable) }
            if !process.isRunning {
                if exitedAt == nil { exitedAt = now }
                if !readers.contains(true) {
                    return ShellBytes(status: process.terminationStatus, stdout: streams[0], stderr: streams[1])
                }
                // Even calls with no execution deadline cannot wait forever on a grandchild.
                if let exitedAt, exitedAt.duration(to: now) >= .seconds(2) {
                    throw ShellFailure.incompleteOutput(command: executable)
                }
            }
            if inputOpen && inputOffset == bytes.count {
                try? handles[2].close()
                inputOpen = false
            }
            var descriptors = handles.enumerated().map { index, handle in
                let active = index < 2 ? readers[index] : inputOpen
                return pollfd(
                    fd: active ? handle.fileDescriptor : -1,
                    events: Int16(index < 2 ? POLLIN : POLLOUT), revents: 0
                )
            }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 20)
            if ready < 0 {
                if errno == EINTR { continue }
                throw pipeFailure("wait for output", errno)
            }
            for index in 0..<2 where readers[index] && descriptors[index].revents != 0 {
                let chunk = try readChunk(descriptors[index].fd)
                if let chunk {
                    if chunk.isEmpty { readers[index] = false } else {
                        guard chunk.count <= outputLimit - streams[index].count else {
                            throw ShellFailure.outputLimit(
                                command: executable, stream: index == 0 ? "stdout" : "stderr", limit: outputLimit
                            )
                        }
                        streams[index].append(chunk)
                    }
                }
            }
            if inputOpen && descriptors[2].revents != 0 {
                let count = bytes.withUnsafeBytes { buffer in
                    write(descriptors[2].fd, buffer.baseAddress!.advanced(by: inputOffset), min(65_536, bytes.count - inputOffset))
                }
                if count > 0 { inputOffset += count } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    // A child may legitimately reject input with its own useful exit status.
                    // EPIPE closes stdin while stdout/stderr continue to drain that explanation.
                    if errno != EPIPE { throw pipeFailure("write input", errno) }
                    try? handles[2].close()
                    inputOpen = false
                }
            }
        }
    }

    private func readChunk(_ descriptor: Int32) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(descriptor, &buffer, buffer.count)
        if count >= 0 { return Data(buffer.prefix(count)) }
        if errno == EAGAIN || errno == EINTR { return nil }
        throw pipeFailure("read output", errno)
    }

    private func pipeFailure(_ operation: String, _ code: Int32) -> ShellFailure {
        .pipe(command: executable, operation: operation, code: code)
    }

    private func stop(_ process: Process, pid: Int32, ownsGroup: Bool) {
        if ownsGroup { _ = killpg(pid, SIGTERM) } else if process.isRunning { _ = kill(pid, SIGTERM) }
        let grace = ContinuousClock.now.advanced(by: .milliseconds(200))
        while process.isRunning && ContinuousClock.now < grace { Thread.sleep(forTimeInterval: 0.01) }
        if ownsGroup { _ = killpg(pid, SIGKILL) } else if process.isRunning { _ = kill(pid, SIGKILL) }
        // Reap only the child we created. SIGKILL cannot be ignored by a userspace process.
        process.waitUntilExit()
    }
}

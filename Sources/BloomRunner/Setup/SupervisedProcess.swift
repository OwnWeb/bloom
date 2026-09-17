import BloomCore
import Foundation
import Synchronization
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// One long-running command kept alive: started, logged, started again after a crash with a
/// growing wait, and stopped with its whole process group.
///
/// The project's services and Caddy are both this, and neither is a Sprite Service, for the reasons
/// under "Setup" in docs/REMOTE-WORKSPACES.md.
///
/// **Stopping signals the group, not the pid, and keeps doing so after the leader is gone.**
/// `sh -c "npm run dev"` is three processes deep by the time Vite is listening, and `sh` exiting on
/// SIGTERM says nothing about the node process under it holding port 5173. The child is the leader
/// of its own group (Foundation spawns it that way on both platforms, measured on Linux), so the
/// group id is the pid recorded at launch, and `killpg` on it still reaches every member after the
/// leader has been reaped. A kernel does not hand out a pid that is still a live group's id, so the
/// number cannot have come to mean somebody else while any member is alive.
final class SupervisedProcess: Sendable {
    enum Event: Sendable {
        case launched
        case exited(status: Int32, restartingIn: Duration)
    }

    struct Command: Sendable, Hashable {
        var executable: String
        var arguments: [String]
        var workingDirectory: String?
        var environment: [String: String]
    }

    private struct State {
        var group: pid_t = 0
        var stopping = false
        var loop: Task<Void, Never>?
    }

    private let command: Command
    private let logPath: String
    private let logLimit: Int
    private let backoff: RestartBackoff
    private let stopGrace: Duration
    private let onEvent: @Sendable (Event) async -> Void
    private let state = Mutex(State())

    init(
        command: Command, logPath: String, logLimit: Int, backoff: RestartBackoff, stopGrace: Duration,
        onEvent: @escaping @Sendable (Event) async -> Void
    ) {
        self.command = command
        self.logPath = logPath
        self.logLimit = logLimit
        self.backoff = backoff
        self.stopGrace = stopGrace
        self.onEvent = onEvent
    }

    func start() {
        state.withLock { state in
            guard state.loop == nil, !state.stopping else { return }
            state.loop = Task { await self.supervise() }
        }
    }

    /// SIGTERM to the group, SIGKILL to whatever is left of it after the grace period, and no
    /// restart afterwards. Returns once the supervising loop has ended.
    func stop() async {
        let (group, loop) = state.withLock { state in
            state.stopping = true
            return (state.group, state.loop)
        }
        if group > 0 {
            Self.signal(group: group, SIGTERM)
            let deadline = ContinuousClock.now + stopGrace
            while Self.isAlive(group: group), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if Self.isAlive(group: group) { Self.signal(group: group, SIGKILL) }
        }
        // Cancelling ends a backoff sleep at once. A process that is still being read from ends its
        // stream on the signal above, so this never cuts the tail off a log.
        loop?.cancel()
        await loop?.value
    }

    private var isStopping: Bool { state.withLock { $0.stopping } }

    private func supervise() async {
        var backoff = backoff
        let log = CappedLogFile(path: logPath, limit: logLimit)
        defer { log.close() }
        while !isStopping, !Task.isCancelled {
            let process = StreamingProcess(
                executable: command.executable, arguments: command.arguments,
                cwd: command.workingDirectory, environment: command.environment
            )
            let lines = process.lines
            let began = ContinuousClock.now
            let pid = process.processIdentifier
            let group: pid_t = pid > 0 && getpgid(pid) == pid && pid != getpgrp() ? pid : 0
            // A stop that landed between the launch and this line found no group to signal, so the
            // loop signals it itself rather than leaving a process nobody will ever stop.
            let stoppedMeanwhile = state.withLock { state -> Bool in
                state.group = group
                return state.stopping
            }
            if stoppedMeanwhile {
                if group > 0 { Self.signal(group: group, SIGKILL) } else { process.kill() }
            } else if pid > 0 {
                await onEvent(.launched)
            }
            do {
                for try await line in lines { log.append(line) }
            } catch {
                log.append("[bloom] \(error)")
            }
            let status = await process.exitStatus
            // The shell is gone but a child it started (a dev server forked into the background)
            // can still hold the port, and would make every restart fail on it. The group stays
            // recorded until that is dealt with, so a stop arriving meanwhile signals it too.
            if group > 0, Self.isAlive(group: group) {
                Self.signal(group: group, SIGTERM)
                let deadline = ContinuousClock.now + stopGrace
                while Self.isAlive(group: group), ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Self.isAlive(group: group) { Self.signal(group: group, SIGKILL) }
            }
            state.withLock { $0.group = 0 }
            guard !isStopping else { break }
            let delay = backoff.delay(afterRunningFor: ContinuousClock.now - began)
            log.append("[bloom] Exited with status \(status). Starting again in \(Self.describe(delay)).")
            await onEvent(.exited(status: status, restartingIn: delay))
            try? await Task.sleep(for: delay)
        }
    }

    static func describe(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return seconds >= 1 ? "\(Int(seconds.rounded())) s" : "\(Int((seconds * 1_000).rounded())) ms"
    }

    private static func signal(group: pid_t, _ signal: Int32) {
        _ = killpg(group, signal)
    }

    /// Whether any process is left in the group. A leader waiting to be reaped still counts, for
    /// the moment it takes Foundation to reap it, which only ever errs towards waiting.
    private static func isAlive(group: pid_t) -> Bool {
        killpg(group, 0) == 0
    }
}

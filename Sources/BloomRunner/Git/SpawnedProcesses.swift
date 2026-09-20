import BloomCore
import Foundation

/// What the Runner started, and for whom, so a local caller can be recognised by its pid.
///
/// **The environment cannot answer this any more.** Before the sandbox, the git credential route
/// read `BLOOM_CHAT_ID` out of the calling process's ancestor in `/proc`. A sandboxed agent runs as
/// another user, and `/proc/<pid>/environ` is readable only by that process's own user, so the
/// Runner cannot look. What it can read is `/proc/<pid>/stat`, which is world-readable and holds the
/// parent, and what it knows for certain is the pid of every process it started itself. So the
/// question becomes: which of my own children does this caller descend from? That is M1 in the
/// security review of 19 September 2026, and unlike an environment variable a pid cannot be claimed.
public actor SpawnedProcesses {
    /// What a process was started for.
    public enum Purpose: Sendable, Hashable {
        /// An agent running a chat's turns.
        case chat(SessionID)
        /// The tmux server, whose panes are terminals. Which terminal is asked of tmux, by pane pid.
        case terminalServer
    }

    private var purposes: [Int32: Purpose] = [:]
    private let parent: @Sendable (Int32) -> Int32?

    public init(parent: @escaping @Sendable (Int32) -> Int32? = SpawnedProcesses.parentFromProc) {
        self.parent = parent
    }

    public func record(pid: Int32, for purpose: Purpose) {
        guard pid > 1 else { return }
        purposes[pid] = purpose
    }

    public func forget(pid: Int32) {
        purposes.removeValue(forKey: pid)
    }

    /// What `pid` descends from, and the pid of that ancestor, or nil when it descends from nothing
    /// this Runner started. A depth limit, because the table is read while it is changing.
    public func origin(of pid: Int32) -> (purpose: Purpose, ancestor: Int32)? {
        var current = pid
        for _ in 0..<64 {
            if let purpose = purposes[current] { return (purpose, current) }
            guard current > 1, let next = parent(current), next != current else { return nil }
            current = next
        }
        return nil
    }

    /// Every pid between `pid` and the root, itself first, for a caller that has to match one of
    /// several pids it did not start, such as a tmux pane.
    public func ancestry(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        for _ in 0..<64 {
            chain.append(current)
            guard current > 1, let next = parent(current), next != current else { break }
            current = next
        }
        return chain
    }

    /// `/proc/<pid>/stat`, whose fourth field is the parent. The comm field can hold spaces and
    /// brackets, so it is read after the last `)` rather than by splitting the whole line.
    public static let parentFromProc: @Sendable (Int32) -> Int32? = { pid in
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 1 ? Int32(fields[1]) : nil
    }
}

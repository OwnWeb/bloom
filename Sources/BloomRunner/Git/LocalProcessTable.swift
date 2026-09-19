import BloomCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Which process on this machine is on the other end of a loopback connection, and which of Bloom
/// Runner's own children it descends from, read from `/proc`.
///
/// **What the git credential route asks before it hands out a person's write token.** Every process
/// on the machine can read the local secret, so a chat id or a terminal name in the request proves
/// nothing: a setup script or a service could name a chat with a running turn and push as that
/// person, which the security review of 19 September 2026 found as M1. A process's parent, though,
/// is the kernel's to say. Walking up from the caller to the child Bloom Runner started itself
/// finds what the caller really is: an agent (started with `BLOOM_CHAT_ID`), a publishing command
/// (with `BLOOM_TURN_ID`), a shell in one of the Runner's terminals (a pane of the tmux server it
/// started, with `BLOOM_TERMINAL`), or something else, which gets a read-only token.
///
/// **What this does not stop** is code that runs as the same user reaching into one of those
/// processes, or opening a window in the Runner's tmux server, which the same user can. Running the
/// agent, terminals and scripts as a second user is what ends that; this is the part that does not
/// need it.
///
/// Linux only. Anywhere `/proc` is not, every lookup answers nil, which the route reads as
/// "nobody in particular" and answers read-only.
struct LocalProcessTable: Sendable {
    var root: String = "/proc"
    var runner: Int32 = getpid()

    /// What the caller on loopback port `port` descends from, or nil when it cannot be said.
    func origin(ofLocalPort port: Int, terminalServer: Int32?) -> LocalOrigin? {
        guard let caller = pid(holdingLocalPort: port) else { return nil }
        var chain: [Int32] = []
        var current = caller
        // Deep enough for git under a hook under a shell under an agent, and a bound on a table
        // that is changing while it is read.
        while current > 1, chain.count < 64 {
            chain.append(current)
            guard let parent = parent(of: current) else { return nil }
            if parent == runner {
                let spawned = environment(of: current) ?? [:]
                // In a terminal, the Runner's child is the tmux server and the one below it is the
                // pane's shell, which is where the terminal's name is.
                var terminal: String?
                if current == terminalServer, chain.count >= 2 {
                    terminal = environment(of: chain[chain.count - 2])?["BLOOM_TERMINAL"]
                }
                return LocalOrigin(chatID: spawned["BLOOM_CHAT_ID"].map(SessionID.init), turnID: spawned["BLOOM_TURN_ID"], terminal: terminal)
            }
            current = parent
        }
        return nil
    }

    /// The process holding the loopback socket whose own port is `port`, which is the client's end
    /// of a connection this server accepted.
    func pid(holdingLocalPort port: Int) -> Int32? {
        guard let inode = socketInode(localPort: port) else { return nil }
        let target = "socket:[\(inode)]"
        let files = FileManager.default
        for pid in processes() {
            let directory = root + "/\(pid)/fd"
            guard let descriptors = try? files.contentsOfDirectory(atPath: directory) else { continue }
            for descriptor in descriptors where (try? files.destinationOfSymbolicLink(atPath: directory + "/" + descriptor)) == target {
                return pid
            }
        }
        return nil
    }

    func parent(of pid: Int32) -> Int32? {
        guard let stat = try? String(contentsOfFile: root + "/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        // `pid (comm) state ppid ...`, and `comm` can hold spaces and brackets, so read after the last.
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 1 ? Int32(fields[1]) : nil
    }

    func environment(of pid: Int32) -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: root + "/\(pid)/environ") else { return nil }
        var environment: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    private func processes() -> [Int32] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).compactMap { Int32($0) }
    }

    /// `/proc/net/tcp` and `tcp6`: `sl local_address rem_address st ... uid timeout inode`, the
    /// address as hex `ADDR:PORT`.
    private func socketInode(localPort port: Int) -> String? {
        let wanted = String(format: "%04X", port)
        for table in ["tcp", "tcp6"] {
            guard let text = try? String(contentsOfFile: root + "/net/" + table, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count > 9, fields[1].split(separator: ":").last.map(String.init) == wanted,
                      fields[9] != "0" else { continue }
                return String(fields[9])
            }
        }
        return nil
    }
}

/// What a local caller descends from, as far as the Runner started it. See `LocalProcessTable`.
struct LocalOrigin: Sendable, Hashable {
    var chatID: SessionID?
    var turnID: String?
    var terminal: String?
}

import Foundation

/// Whether anything is actually running under a step, read from `/proc`.
///
/// **Because silence is not death, and a heartbeat from the wrong place is worse than silence.**
/// A setup step that has printed nothing for five minutes is indistinguishable, from outside, from
/// one that has hung; runbloom.app restarted a machine on exactly that inference while `composer`
/// and `bun` were still installing, throwing away their caches so that the retry was slower than
/// the run it killed. The obvious fix is for the machine to say "this step is alive", and it is the
/// wrong fix: during the one hang anybody has actually seen, the server was healthy. It answered
/// health, it answered RPC, it posted summaries, and its own watchdog woke on its timer, over a
/// child that had been dead for seventeen minutes. **A liveness signal sourced from the process
/// doing the asking would have reported that hang as healthy for its whole duration.**
///
/// So the evidence here is about the child and nothing else: how many processes are alive under it,
/// how many have exited and not been collected, and how much CPU the tree has used. The first two
/// separate the two cases that have actually occurred, `S` against `Z`. The third is positive
/// evidence of work.
///
/// **CPU that has not moved is not death, and the code must keep saying so.** A process blocked on
/// a slow network read for five minutes is working exactly as intended, so a tree that used no CPU
/// is reported as alive with a qualification rather than as stalled. This is the sentence somebody
/// will eventually be tempted to simplify into "no CPU means stuck"; it is wrong, and every case of
/// a big download in a `prepare` script is a counter-example.
///
/// Read from `/proc` rather than by running `ps`, for the reason `ListeningPorts` gives: this is
/// called from a watchdog that exists to notice a subprocess that will not return, and starting a
/// subprocess to do it is the same bug wearing a hat.
public enum StepLiveness {
    /// What was found under one step's child, at one moment.
    public struct Reading: Sendable, Hashable {
        /// The child and every descendant of it that is not a zombie.
        public var running: Int
        /// Descendants that have exited and not been collected. **One of these with nothing else
        /// running is the fault `StreamingProcess.reapWhenFoundationDoesNot` exists for**, seen
        /// from the other side.
        public var defunct: Int
        /// User plus system time across the tree, in clock ticks, as `/proc` reports them. Compared
        /// with the previous reading rather than read as a total.
        public var ticks: UInt64

        public init(running: Int, defunct: Int, ticks: UInt64) {
            self.running = running
            self.defunct = defunct
            self.ticks = ticks
        }

        public var isAlive: Bool { running > 0 }
    }

    /// What the machine says about a step, which is what runbloom.app acts on. **The verdict is the
    /// machine's, because the machine is the only party that can see the child**; the numbers travel
    /// with it so that a decision taken on it can be argued with afterwards.
    public enum Verdict: String, Sendable, Codable, Hashable {
        /// Something under this step used CPU since the last look. It is working.
        case working
        /// Something is alive but has used no CPU since the last look. **Not a stall**: waiting on
        /// a download, a lock or a database is this.
        case waiting
        /// Nothing is alive under this step. The only state in which restarting is the right answer.
        case nothingAlive = "nothing_alive"

        public var sentence: String {
            switch self {
            case .working: "working"
            case .waiting: "alive, and waiting on something rather than using the processor"
            case .nothingAlive: "nothing running"
            }
        }
    }

    /// **Only `nothingAlive` is a reason to act**, and the other two exist so that the sentence a
    /// person reads says which kind of alive it is.
    ///
    /// With no earlier reading to compare against, the ticks are still evidence: they count from
    /// the process's own start, so a tree that has used any CPU at all has done some work. That is
    /// weaker than "it used CPU in the last thirty seconds" and it is honest about which it is.
    public static func verdict(_ now: Reading, since previous: Reading?) -> Verdict {
        guard now.isAlive else { return .nothingAlive }
        guard let previous else { return now.ticks > 0 ? .working : .waiting }
        return now.ticks > previous.ticks ? .working : .waiting
    }

    /// One process's line of `/proc/<pid>/stat`: its id, its parent, whether it is a zombie, and
    /// the processor time it has used.
    ///
    /// **The command is skipped rather than parsed.** It is the only field that can contain a
    /// space or a bracket, `/proc` does not escape it, and a process is free to call itself
    /// `sh (1) Z 1 1`. Everything before the **last** `)` is therefore thrown away, which is what
    /// the kernel's own documentation tells readers to do, and the fields are counted from there.
    static func parse(stat text: String) -> (pid: Int32, parent: Int32, isDefunct: Bool, ticks: UInt64)? {
        guard let close = text.lastIndex(of: ")"),
              let pid = Int32(text[text.startIndex..<(text.firstIndex(of: "(") ?? text.startIndex)]
                  .trimmingCharacters(in: .whitespaces)) else { return nil }
        let fields = text[text.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
        // state, ppid, pgrp, session, tty, tpgid, flags, minflt, cminflt, majflt, cmajflt, utime, stime
        guard fields.count > 12, let parent = Int32(fields[1]),
              let user = UInt64(fields[11]), let system = UInt64(fields[12]) else { return nil }
        return (pid, parent, fields[0] == "Z", user + system)
    }

    /// The child and everything under it, from every `stat` line on the machine.
    ///
    /// **Walked by parent rather than by process group**, because nothing here puts a step in a
    /// group of its own, and a group id read from the step's own child would collect whatever else
    /// the machine happens to have put there. A parent walk needs no change to how anything is
    /// launched, which matters for a signal whose whole job is to describe what is already running.
    static func reading(child: Int32, stats: [String]) -> Reading {
        var byParent: [Int32: [(pid: Int32, isDefunct: Bool, ticks: UInt64)]] = [:]
        var own: (isDefunct: Bool, ticks: UInt64)?
        for line in stats {
            guard let parsed = parse(stat: line) else { continue }
            if parsed.pid == child { own = (parsed.isDefunct, parsed.ticks) }
            byParent[parsed.parent, default: []].append((parsed.pid, parsed.isDefunct, parsed.ticks))
        }
        guard let own else { return Reading(running: 0, defunct: 0, ticks: 0) }
        var running = own.isDefunct ? 0 : 1
        var defunct = own.isDefunct ? 1 : 0
        var ticks = own.ticks
        var queue = [child]
        // A parent map from one pass of /proc cannot contain a cycle, so a seen set would only
        // guard against a file that changed under us; the depth bound below is that guard.
        var depth = 0
        while !queue.isEmpty, depth < 64 {
            depth += 1
            var next: [Int32] = []
            for parent in queue {
                for entry in byParent[parent] ?? [] where entry.pid != parent {
                    if entry.isDefunct { defunct += 1 } else { running += 1 }
                    ticks += entry.ticks
                    next.append(entry.pid)
                }
            }
            queue = next
        }
        return Reading(running: running, defunct: defunct, ticks: ticks)
    }

    /// Every process on the machine, as `/proc` has them this instant. Nil off Linux, where there
    /// is no `/proc` and no machine.
    public static func read(child: Int32, procfs: String = "/proc") -> Reading? {
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: procfs) else { return nil }
        var stats: [String] = []
        for entry in entries where Int32(entry) != nil {
            // A process that exits between the listing and the read is ordinary, not an error.
            guard let text = try? String(contentsOfFile: procfs + "/" + entry + "/stat", encoding: .utf8) else { continue }
            stats.append(text)
        }
        return reading(child: child, stats: stats)
        #else
        return nil
        #endif
    }
}

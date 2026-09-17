import Foundation

/// What a Cloud workspace's machine reports it used, accumulated between reports.
///
/// **Counters are cumulative since boot, so a lost or repeated report changes nothing.**
/// runbloom.app takes the difference between two reports from the same boot; a report that went
/// missing is covered by the next one, and one that arrived twice is ignored by its sequence. A
/// new boot starts everything at zero under a new boot id, which is how a cold wake reads.
///
/// Memory and awake time are integrated from samples taken while the machine is held awake, every
/// fifteen seconds. **A gap between samples far longer than that is a pause,** because a paused
/// machine's processes are frozen and its timers do not fire: the gap is not counted, and the next
/// sample records a wake. That is the only way the machine can see its own pause.
///
/// Codable, because the server keeps it in its database between restarts in one boot: a server
/// update restarts the process, and a sequence starting again at one would be ignored as a repeat.
public struct RemoteUsageMeter: Codable, Sendable, Hashable {
    public static let sampleInterval: TimeInterval = 15
    /// A gap past which the machine is taken to have been paused rather than slow.
    public static let pauseGap: TimeInterval = 45

    public private(set) var bootID: String
    public private(set) var sequence = 0
    public private(set) var cpuSeconds = 0.0
    public private(set) var memoryGBSeconds = 0.0
    public private(set) var awakeSeconds = 0.0
    public private(set) var events: [UsageEvent] = []
    public private(set) var lastSampleAt: Date?
    public private(set) var lastDisk: UsageReport.Disk?
    public private(set) var lastDiskAt: Date?

    public init(bootID: String) {
        self.bootID = bootID
    }

    /// Takes a reading. `awake` is whether the machine was held awake since the last one.
    ///
    /// Answers true when the reading shows the machine was paused since the last one, so the
    /// caller can record why it is awake again.
    @discardableResult
    public mutating func sample(_ sample: MachineUsageReading, at date: Date, awake: Bool) -> Bool {
        if sample.bootID != bootID { self = RemoteUsageMeter(bootID: sample.bootID) }
        cpuSeconds = max(cpuSeconds, sample.cpuSeconds)
        defer { lastSampleAt = date }
        guard let last = lastSampleAt else { return false }
        let gap = date.timeIntervalSince(last)
        guard gap > 0 else { return false }
        if gap > Self.pauseGap { return true }
        if awake {
            awakeSeconds += gap
            memoryGBSeconds += Double(sample.memoryUsedBytes) / 1_073_741_824 * gap
        }
        if let disk = sample.diskUsedBytes { lastDisk = UsageReport.Disk(usedBytes: disk, at: date) }
        return false
    }

    public mutating func record(_ event: UsageEvent) {
        events.append(event)
        // Bounded, so a machine that cannot reach runbloom.app for a week does not grow without
        // end. The counters still carry the totals; only the oldest detail is lost.
        if events.count > 2_000 { events.removeFirst(events.count - 2_000) }
    }

    /// The next report, which takes the events recorded since the last one. Disk goes in hourly
    /// and whenever `includingDisk` says so, which the caller does at every release.
    public mutating func report(at date: Date, includingDisk: Bool) -> UsageReport {
        sequence += 1
        var disk: UsageReport.Disk?
        if let lastDisk, includingDisk || lastDiskAt.map({ date.timeIntervalSince($0) >= 3_600 }) ?? true {
            disk = lastDisk
            lastDiskAt = date
        }
        let report = UsageReport(
            machineBootID: bootID, sequence: sequence, events: events,
            counters: .init(cpuSeconds: cpuSeconds, memoryGBSeconds: memoryGBSeconds, awakeSeconds: awakeSeconds), disk: disk
        )
        events.removeAll()
        return report
    }
}

/// One reading from the machine, as the meter needs it.
public struct MachineUsageReading: Sendable, Hashable {
    public var cpuSeconds: Double
    public var memoryUsedBytes: Int64
    public var diskUsedBytes: Int64?
    public var bootID: String

    public init(cpuSeconds: Double, memoryUsedBytes: Int64, diskUsedBytes: Int64?, bootID: String) {
        self.cpuSeconds = cpuSeconds
        self.memoryUsedBytes = memoryUsedBytes
        self.diskUsedBytes = diskUsedBytes
        self.bootID = bootID
    }
}

/// Something that happened, in the words runbloom.app aggregates.
public struct UsageEvent: Codable, Sendable, Hashable {
    public var kind: String
    public var at: Date
    public var reason: String?
    public var outcome: String?
    public var turnID: String?
    public var userID: String?
    public var agent: String?

    public static func awake(_ reason: RemoteAwakePolicy.Reason, at date: Date) -> Self {
        Self(kind: "awake", at: date, reason: reason.rawValue)
    }

    public static func released(at date: Date) -> Self { Self(kind: "released", at: date) }
    public static func setupStarted(at date: Date) -> Self { Self(kind: "setup_started", at: date) }

    public static func setupFinished(succeeded: Bool, at date: Date) -> Self {
        Self(kind: "setup_finished", at: date, outcome: succeeded ? "succeeded" : "failed")
    }

    public static func turnStarted(turnID: String, userID: String?, agent: AgentKind, at date: Date) -> Self {
        Self(kind: "turn_started", at: date, turnID: turnID, userID: userID, agent: agent.wireName)
    }

    public static func turnFinished(turnID: String, at date: Date) -> Self { Self(kind: "turn_finished", at: date, turnID: turnID) }

    public init(kind: String, at: Date, reason: String? = nil, outcome: String? = nil, turnID: String? = nil, userID: String? = nil, agent: String? = nil) {
        self.kind = kind
        self.at = at
        self.reason = reason
        self.outcome = outcome
        self.turnID = turnID
        self.userID = userID
        self.agent = agent
    }

    enum CodingKeys: String, CodingKey {
        case kind, at, reason, outcome, agent
        case turnID = "turn_id"
        case userID = "user_id"
    }
}

/// `POST /api/machine/workspaces/{id}/usage`. See docs/REMOTE-WORKSPACES.md, "Usage".
public struct UsageReport: Codable, Sendable, Hashable {
    public struct Counters: Codable, Sendable, Hashable {
        public var cpuSeconds: Double
        public var memoryGBSeconds: Double
        public var awakeSeconds: Double

        enum CodingKeys: String, CodingKey {
            case cpuSeconds = "cpu_seconds"
            case memoryGBSeconds = "memory_gb_seconds"
            case awakeSeconds = "awake_seconds"
        }
    }

    public struct Disk: Codable, Sendable, Hashable {
        public var usedBytes: Int64
        public var at: Date

        enum CodingKeys: String, CodingKey {
            case usedBytes = "used_bytes"
            case at
        }
    }

    public var machineBootID: String
    public var sequence: Int
    public var events: [UsageEvent]
    public var counters: Counters
    public var disk: Disk?

    enum CodingKeys: String, CodingKey {
        case machineBootID = "machine_boot_id"
        case sequence, events, counters, disk
    }
}
